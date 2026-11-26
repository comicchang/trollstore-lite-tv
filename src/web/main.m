// tsltvweb —— TrollStore Lite TV 的 Web 前端（tvOS 原生 CLI 程序，root 运行）
//
// 为什么有它：tvOS 的 GUI 必须屏幕亮着才能启动（PineBoard 不亮屏就不拉起 app）。
// 这个程序不需要任何显示，直接监听 TCP，用浏览器就能完成「装 / 卸 / 校验」。
//
// 路由：
//   GET  /              管理页面（列表 + 上传 + 操作）
//   GET  /api/probe     机器可读状态（TSV）
//   POST /api/install?name=xxx.ipa   请求体 = ipa 字节流
//   POST /api/uninstall?bid=<id>
//   POST /api/verify
//   POST /api/trust     重新信任全部
//
// 安全：只绑定在本机网络，命令参数做白名单校验，不接受任意路径。

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <sys/wait.h>
#include <spawn.h>

// 不同进程看到的 /usr 可能不同（roothide vroot），运行时解析真实路径
static NSString *CLIPath(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray arrayWithObjects:
        @"/usr/libexec/tsltv/tsltv",
        nil];
    for (NSString *e in [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil]) {
        if (![e hasPrefix:@".jbroot-"]) continue;
        [cands addObject:[NSString stringWithFormat:
            @"/var/containers/Bundle/Application/%@/usr/libexec/tsltv/tsltv", e]];
    }
    for (NSString *c in cands) {
        if ([fm isExecutableFileAtPath:c]) { cached = c; return cached; }
    }
    cached = cands.firstObject;
    return cached;
}
static NSString *const kUploadDir = @"/var/tmp/tsltv-upload";

#pragma mark - 与 tsltvd 通信（纯文件 I/O，不 fork/exec）

static NSString *ATRunDir(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray arrayWithObjects:
        @"/var/run/tsltv",
        @"/private/var/run/tsltv",
        @"/rootfs/private/var/run/tsltv",
        nil];
    for (NSString *e in [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil]) {
        if (![e hasPrefix:@".jbroot-"]) continue;
        [cands addObject:[NSString stringWithFormat:
            @"/var/containers/Bundle/Application/%@/var/run/tsltv", e]];
    }
    for (NSString *c in cands) {
        if ([fm fileExistsAtPath:[c stringByAppendingPathComponent:@"req.fifo"]]) {
            cached = c; return cached;
        }
    }
    return cands.firstObject;
}

// 发一条命令给 daemon，等它写完响应
static NSString *ATDaemonTimeout(NSString *command, int maxSecs, int *rcOut) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *run = ATRunDir();
    NSString *fifo = [run stringByAppendingPathComponent:@"req.fifo"];
    if (![fm fileExistsAtPath:fifo]) {
        if (rcOut) *rcOut = -1;
        return [NSString stringWithFormat:@"daemon 不可用（%@ 不存在）", fifo];
    }
    unsigned long long base = (unsigned long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
    NSString *ident = [NSString stringWithFormat:@"%llu%03u", base, arc4random_uniform(1000)];
    NSString *line = [NSString stringWithFormat:@"%@\t%@\n", ident, command];

    FILE *fp = fopen(fifo.fileSystemRepresentation, "w");
    if (!fp) { if (rcOut) *rcOut = -1; return @"写 req.fifo 失败"; }
    fwrite(line.UTF8String, 1, strlen(line.UTF8String), fp);
    fclose(fp);

    NSString *done = [run stringByAppendingPathComponent:[ident stringByAppendingString:@".done"]];
    NSString *outp = [run stringByAppendingPathComponent:[ident stringByAppendingString:@".out"]];
    NSString *rcp  = [run stringByAppendingPathComponent:[ident stringByAppendingString:@".rc"]];

    int iters = maxSecs * 50;          // 20ms 粒度
    for (int i = 0; i < iters; i++) {
        if ([fm fileExistsAtPath:done]) break;
        usleep(20 * 1000);
    }
    if (![fm fileExistsAtPath:done]) {
        if (rcOut) *rcOut = -1;
        return @"daemon 超时";
    }
    NSString *text = [NSString stringWithContentsOfFile:outp encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *rcs = [NSString stringWithContentsOfFile:rcp encoding:NSUTF8StringEncoding error:nil] ?: @"0";
    if (rcOut) *rcOut = rcs.intValue;
    [fm removeItemAtPath:outp error:nil];
    [fm removeItemAtPath:rcp error:nil];
    [fm removeItemAtPath:done error:nil];
    return text;
}

static NSString *ATDaemon(NSString *command, int *rcOut) {
    return ATDaemonTimeout(command, 180, rcOut);   // 大 ipa 安装可能要几十秒
}

static NSString *Esc(NSString *s) {
    if (!s) return @"";
    NSString *r = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    r = [r stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    r = [r stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    r = [r stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    r = [r stringByReplacingOccurrencesOfString:@"'" withString:@"&#39;"];
    return r;
}

static NSString *UrlDecode(NSString *s) {
    return [s stringByRemovingPercentEncoding] ?: s;
}

// 只允许安全字符，防止命令注入
static BOOL SafeToken(NSString *s) {
    if (s.length == 0 || s.length > 200) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+"];
    return [s rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

#pragma mark - HTTP

static NSData *HttpResponse(int code, NSString *ctype, NSData *body) {
    NSString *reason = code == 200 ? @"OK" : (code == 400 ? @"Bad Request" :
                        (code == 404 ? @"Not Found" : @"Internal Server Error"));
    NSMutableData *d = [NSMutableData data];
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        code, reason, ctype, (unsigned long)body.length];
    [d appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:body];
    return d;
}

static void WriteAll(int fd, NSData *d) {
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) { if (errno == EINTR) continue; break; }
        p += n; left -= (size_t)n;
    }
}

static NSString *ReadHeaders(int fd, NSUInteger *contentLength, NSMutableData *preBody) {
    NSMutableData *buf = [NSMutableData data];
    uint8_t tmp[4096];
    NSInteger headerEnd = -1;
    while (headerEnd < 0) {
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        NSRange r = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                             options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) headerEnd = (NSInteger)(r.location + r.length);
        if (buf.length > 64 * 1024) break;
    }
    if (headerEnd < 0) return nil;
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)]
                                           encoding:NSUTF8StringEncoding];
    *contentLength = 0;
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:c.location] lowercaseString];
        NSString *v = [[line substringFromIndex:c.location + 1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:@"content-length"]) *contentLength = (NSUInteger)v.integerValue;
    }
    if (buf.length > (NSUInteger)headerEnd) {
        [preBody appendData:[buf subdataWithRange:NSMakeRange((NSUInteger)headerEnd,
                                                             buf.length - (NSUInteger)headerEnd)]];
    }
    return head;
}

#pragma mark - 页面

static NSString *TVCachedVersion(void) {
    static NSString *cached = nil;
    static time_t at = 0;
    time_t now = time(NULL);
    if (cached && (now - at) < 60) return cached;
    NSString *verPath = [[CLIPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"VERSION"];
    NSString *v = [[NSString stringWithContentsOfFile:verPath encoding:NSUTF8StringEncoding error:nil]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (v.length == 0) {
        int rc = 0;
        v = [ATDaemonTimeout(@"version", 5, &rc) stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rc != 0) v = nil;
    }
    cached = v.length ? v : @"unknown";
    at = now;
    return cached;
}

// 异步探测缓存：命中立即返回（<50ms），过期在后台刷新，不阻塞首页打开
static pthread_mutex_t gProbeMu = PTHREAD_MUTEX_INITIALIZER;
static NSString *gProbeRows = nil;
static time_t gProbeAt = 0;
static BOOL gProbeRefreshing = NO;

static void *ProbeRefreshThread(void *arg) {
    (void)arg;
    @autoreleasepool {
        int rc = 0;
        NSString *rows = ATDaemonTimeout(@"probe", 15, &rc);
        pthread_mutex_lock(&gProbeMu);
        if (rows.length > 0 && ![rows hasPrefix:@"daemon 超时"] && ![rows hasPrefix:@"daemon 不可用"]) {
            gProbeRows = rows;
            gProbeAt = time(NULL);
        }
        gProbeRefreshing = NO;
        pthread_mutex_unlock(&gProbeMu);
    }
    return NULL;
}

static void RefreshProbeAsync(void) {
    pthread_mutex_lock(&gProbeMu);
    if (gProbeRefreshing) {
        pthread_mutex_unlock(&gProbeMu);
        return;
    }
    gProbeRefreshing = YES;
    pthread_mutex_unlock(&gProbeMu);
    pthread_t th;
    if (pthread_create(&th, NULL, ProbeRefreshThread, NULL) == 0) {
        pthread_detach(th);
    } else {
        pthread_mutex_lock(&gProbeMu);
        gProbeRefreshing = NO;
        pthread_mutex_unlock(&gProbeMu);
    }
}

static void InvalidateProbeCache(void) {
    pthread_mutex_lock(&gProbeMu);
    gProbeAt = 0;
    pthread_mutex_unlock(&gProbeMu);
    RefreshProbeAsync();
}

static NSString *ProbeForPage(void) {
    time_t now = time(NULL);
    pthread_mutex_lock(&gProbeMu);
    NSString *cached = gProbeRows;
    time_t at = gProbeAt;
    pthread_mutex_unlock(&gProbeMu);

    if (cached) {
        if ((now - at) >= 15) RefreshProbeAsync();
        return cached;
    }
    int rc = 0;
    NSString *rows = ATDaemonTimeout(@"probe", 5, &rc);
    if (rows.length > 0 && ![rows hasPrefix:@"daemon 超时"] && ![rows hasPrefix:@"daemon 不可用"]) {
        pthread_mutex_lock(&gProbeMu);
        gProbeRows = rows;
        gProbeAt = time(NULL);
        pthread_mutex_unlock(&gProbeMu);
        return rows;
    }
    RefreshProbeAsync();
    return @"";
}

#pragma mark - 油猴脚本托管（供 YouTube TV / Cobalt 本地热加载）

static NSString *const kUserscriptsDir = @"/var/mobile/Library/tsltv-userscripts";
static pthread_mutex_t gUSMu = PTHREAD_MUTEX_INITIALIZER;
static unsigned long gUSHits = 0;
static time_t gUSLastHit = 0;

static NSString *UserscriptsDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kUserscriptsDir]) {
        [fm createDirectoryAtPath:kUserscriptsDir withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0755} error:nil];
    }
    return kUserscriptsDir;
}

static BOOL SafeScriptName(NSString *s) {
    if (!SafeToken(s)) return NO;
    if ([s containsString:@".."]) return NO;
    return [s hasSuffix:@".js"];
}

static NSString *UserscriptsBundleJS(void) {
    NSString *dir = UserscriptsDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [[fm contentsOfDirectoryAtPath:dir error:nil]
                                  sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *js = [NSMutableString stringWithString:
        @"/* TrollStore Lite TV Userscripts Bundle */\n"];
    NSUInteger loaded = 0;
    for (NSString *name in items) {
        if (![name hasSuffix:@".js"] || [name hasPrefix:@"."]) continue;
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSString *src = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!src.length) continue;
        loaded++;
        [js appendFormat:@"\n/* === %@ === */\n(function(){try{\n%@\n}catch(e){console.error('[tsltv-us %@]',e);}})();\n",
         name, src, name];
    }
    [js appendFormat:@"\nwindow.__tsltvUserscriptsLoaded=%lu;\n", (unsigned long)loaded];
    pthread_mutex_lock(&gUSMu);
    gUSHits++;
    gUSLastHit = time(NULL);
    pthread_mutex_unlock(&gUSMu);
    return js;
}

static NSString *UserscriptsTableHTML(NSUInteger *countOut) {
    NSString *dir = UserscriptsDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [[fm contentsOfDirectoryAtPath:dir error:nil]
                                  sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *tr = [NSMutableString string];
    NSUInteger cnt = 0;
    for (NSString *item in items) {
        if ([item hasPrefix:@"."]) continue;
        BOOL enabled = [item hasSuffix:@".js"];
        BOOL disabled = [item hasSuffix:@".js.disabled"];
        if (!enabled && !disabled) continue;
        NSString *baseName = enabled ? item : [item substringToIndex:item.length - 9];
        NSDictionary *attr = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:item] error:nil];
        unsigned long long sz = [attr fileSize];
        cnt++;
        [tr appendFormat:
            @"<tr><td class=bid>%@</td><td class=dim>%.1f KB</td>"
             "<td class=%@>%@</td>"
             "<td><button onclick=\"usAct('toggle','%@')\">%@</button> "
             "<button class=del onclick=\"usAct('delete','%@')\">删除</button></td></tr>",
            Esc(baseName), (double)sz / 1024.0,
            enabled ? @"ok" : @"dim", enabled ? @"已启用" : @"已停用",
            Esc(baseName), enabled ? @"停用" : @"启用",
            Esc(baseName)];
    }
    if (countOut) *countOut = cnt;
    return tr;
}

static NSString *PageHTML(void) {
    NSString *ver = TVCachedVersion();
    NSString *rows = ProbeForPage();

    NSMutableString *tr = [NSMutableString string];
    NSUInteger count = 0;
    for (NSString *line in [rows componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 6) continue;
        count++;
        BOOL trusted = [f[3] isEqualToString:@"1"];
        BOOL reg = [f[4] isEqualToString:@"1"];
        NSString *cdh = (NSString *)f[2];
        NSString *short_ = cdh.length > 12 ? [cdh substringToIndex:12] : cdh;
        [tr appendFormat:
            @"<tr><td class=bid>%@</td><td class=dim>%@</td>"
             "<td class=%@>%@</td><td class=%@>%@</td><td class=dim>%@</td>"
             "<td class=mono>%@…</td>"
             "<td><button class=del onclick=\"act('uninstall','%@')\">卸载</button></td></tr>",
            Esc(f.count > 6 ? f[6] : f[0]), Esc(f.count > 7 ? f[7] : @"-"),
            trusted ? @"ok" : @"bad", trusted ? @"✓" : @"✗",
            reg ? @"ok" : @"bad", reg ? @"✓" : @"✗",
            Esc(f.count > 5 ? f[5] : @"-"), Esc(short_), Esc(f[0])];
    }

    // 用 NSMutableString 拼接：之前整页走一个超长 stringWithFormat，
    // CSS/JS 里任何未转义的 % 都会把后面的内容截掉（列表因此永远为空）。
    NSMutableString *h = [NSMutableString string];
    [h appendString:@"<!doctype html><meta charset=utf-8><title>TrollStore Lite TV</title>"];
    [h appendString:@"<meta name=viewport content='width=device-width,initial-scale=1'>"];
    [h appendString:@"<style>"
        "body{background:#0b0b0d;color:#e8e8ea;font:15px/1.5 -apple-system,system-ui,sans-serif;"
        "margin:0;padding:28px}"
        "h1{font-size:22px;margin:0 0 4px}.sub{color:#8b8b93;margin-bottom:22px}"
        "table{border-collapse:collapse;width:100%}"
        "th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #1e1e22}"
        "th{color:#8b8b93;font-weight:500;font-size:13px}"
        ".bid{font-weight:600}.dim{color:#8b8b93}"
        ".mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}"
        ".ok{color:#39d353}.bad{color:#f0883e}"
        "button{background:#1f6feb;border:0;color:#fff;padding:6px 12px;border-radius:7px;"
        "cursor:pointer;font-size:13px}button:hover{filter:brightness(1.15)}"
        "button.del{background:#8b2c2c}button.del:hover{background:#a83232}"
        "#drop{border:1px dashed #30363d;border-radius:12px;padding:22px;text-align:center;"
        "margin:22px 0;color:#8b8b93}#drop.hot{border-color:#1f6feb;color:#e8e8ea}"
        "#log{white-space:pre-wrap;background:#111114;border:1px solid #1e1e22;border-radius:10px;"
        "padding:14px;font-family:ui-monospace,Menlo,monospace;font-size:12px;min-height:30px;"
        "margin-top:18px}"
        "</style>"];
    [h appendFormat:@"<h1>TrollStore Lite TV</h1><div class=sub>tvOS 应用安装器 · v%@ · "
                    "ad-hoc 签名 + 内核信任缓存</div>", ver];
    [h appendString:@"<div id=drop>把 .ipa 拖到这里，或 <input type=file id=f accept='.ipa' "
                    "style='display:none'><label for=f style='color:#1f6feb;cursor:pointer'>"
                    "选择文件</label></div>"];
    [h appendString:@"<table><thead><tr><th>应用</th><th>版本</th><th>信任</th><th>注册</th>"
                    "<th>来源</th><th>cdhash</th><th></th></tr></thead><tbody id=tb>"];
    [h appendString:tr];
    [h appendString:@"</tbody></table>"];
    [h appendString:@"<div style='margin-top:18px'>"
                    "<button onclick=\"selfUpd()\" style='background:#238636'>更新自身</button>"
                    "<span class=dim style='margin-left:12px;font-size:13px'>"
                    "把新版 deb 的直链填进弹出的输入框（package: trollstore-lite-tv）</span></div>"];
    NSUInteger usCount = 0;
    NSString *usTr = UserscriptsTableHTML(&usCount);
    pthread_mutex_lock(&gUSMu);
    unsigned long hits = gUSHits;
    time_t lastHit = gUSLastHit;
    pthread_mutex_unlock(&gUSMu);
    NSString *hitInfo = @"尚未被拉取";
    if (hits > 0 && lastHit > 0) {
        struct tm tmv;
        localtime_r(&lastHit, &tmv);
        char tbuf[32];
        strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
        hitInfo = [NSString stringWithFormat:@"已拉取 %lu 次（最近 %s）", hits, tbuf];
    }
    [h appendFormat:@"<h2 style='font-size:17px;margin:28px 0 6px'>油猴脚本（YouTube TV / Cobalt 本地热加载）</h2>"
                    "<div class=dim style='font-size:13px;margin-bottom:12px'>"
                    "脚本入口：<span class=mono>http://127.0.0.1:8787/api/userscripts.js</span> · %@ · "
                    "<input type=file id=jsf accept='.js' style='display:none'>"
                    "<label for=jsf style='color:#1f6feb;cursor:pointer'>上传 .js 脚本</label></div>",
                    Esc(hitInfo)];
    [h appendString:@"<table><thead><tr><th>脚本</th><th>大小</th><th>状态</th><th></th></tr></thead><tbody>"];
    if (usCount > 0) {
        [h appendString:usTr];
    } else {
        [h appendString:@"<tr><td colspan=4 class=dim>暂无脚本（上传 .js 后重启 YouTube TVL 自动生效）</td></tr>"];
    }
    [h appendString:@"</tbody></table>"];
    [h appendFormat:@"<div id=log>就绪。已安装 %lu 个应用，%lu 个油猴脚本。</div>",
     (unsigned long)count, (unsigned long)usCount];
    [h appendString:@"<script>"
        "const log=(t)=>{document.getElementById('log').textContent=t};"
        "async function act(cmd,arg){"
        "if(cmd==='uninstall'&&!confirm('确定卸载 '+(arg||'')+' ?'))return;"
        "log('执行 '+cmd+(arg?' '+arg:'')+' …');"
        "const r=await fetch('/api/'+cmd+(arg?'?bid='+encodeURIComponent(arg):'')+'',{method:'POST'});"
        "log(await r.text());setTimeout(()=>location.reload(),1200)}"
        "async function usAct(cmd,name){"
        "if(cmd==='delete'&&!confirm('确定删除脚本 '+name+' ?'))return;"
        "const r=await fetch('/api/userscripts/'+cmd+'?name='+encodeURIComponent(name),{method:'POST'});"
        "log(await r.text());setTimeout(()=>location.reload(),600)}"
        "async function uploadJS(file){"
        "log('上传脚本 '+file.name+'…');"
        "const r=await fetch('/api/userscripts/save?name='+encodeURIComponent(file.name),{method:'POST',body:file});"
        "log(await r.text());setTimeout(()=>location.reload(),600)}"
        "document.getElementById('jsf').onchange=e=>e.target.files[0]&&uploadJS(e.target.files[0]);"
        "async function selfUpd(){"
        "const u=prompt('新版 deb 的 http 直链：','');if(!u)return;"
        "log('正在下载并交给 dpkg…');"
        "const r=await fetch('/api/selfupdate?url='+encodeURIComponent(u),{method:'POST'});"
        "log(await r.text())}"
        "function upload(file){"
        "const t0=Date.now();let timer=null;"
        "const xhr=new XMLHttpRequest();"
        "xhr.open('POST','/api/install?name='+encodeURIComponent(file.name),true);"
        "xhr.upload.onprogress=e=>{"
        "if(!e.lengthComputable)return;"
        "const dt=Math.max((Date.now()-t0)/1000,0.05);"
        "const mb=(e.loaded/1048576).toFixed(1),tot=(e.total/1048576).toFixed(1);"
        "const spd=(e.loaded/1048576/dt).toFixed(1),pct=Math.min(100,Math.round(e.loaded*100/e.total));"
        "log('上传 '+file.name+'：'+pct+'% ('+mb+'/'+tot+' MB · '+spd+' MB/s)…');};"
        "xhr.upload.onload=()=>{"
        "const udt=((Date.now()-t0)/1000).toFixed(1);"
        "const it0=Date.now();"
        "const tick=()=>log('上传完成（用时 '+udt+'s），设备端正在解包 / 签名 / 注册… ('+Math.round((Date.now()-it0)/1000)+'s)');"
        "tick();timer=setInterval(tick,1000);};"
        "xhr.onload=()=>{if(timer)clearInterval(timer);log(xhr.responseText);setTimeout(()=>location.reload(),1500);};"
        "xhr.onerror=()=>{if(timer)clearInterval(timer);log('上传失败（网络中断）');};"
        "log('准备上传 '+file.name+' ('+(file.size/1048576).toFixed(1)+' MB)…');"
        "xhr.send(file)}"
        "const d=document.getElementById('drop'),inp=document.getElementById('f');"
        "inp.onchange=e=>e.target.files[0]&&upload(e.target.files[0]);"
        "['dragenter','dragover'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();"
        "d.classList.add('hot')}));"
        "['dragleave','drop'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();"
        "d.classList.remove('hot')}));"
        "d.addEventListener('drop',e=>{const f=e.dataTransfer.files[0];if(f)upload(f)});"
        "</script>"];
    return h;
}

#pragma mark - 路由

static NSData *HandleRequest(NSString *head, NSData *preBody, int fd) {
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return HttpResponse(400, @"text/plain", [@"bad request" dataUsingEncoding:NSUTF8StringEncoding]);
    NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
    if (parts.count < 2) return HttpResponse(400, @"text/plain", [@"bad request" dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *method = parts[0], *target = parts[1];
    NSString *path = target, *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        path = [target substringToIndex:q.location];
        query = [target substringFromIndex:q.location + 1];
    }

    NSMutableDictionary *qv = [NSMutableDictionary dictionary];
    for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
        NSRange e = [kv rangeOfString:@"="];
        if (e.location == NSNotFound) continue;
        qv[[kv substringToIndex:e.location]] = UrlDecode([kv substringFromIndex:e.location + 1]);
    }

    if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
        return HttpResponse(200, @"text/html; charset=utf-8", [PageHTML() dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/debug"]) {
        int rc1 = 0, rc2 = 0;
        NSString *idOut = [NSString stringWithFormat:@"runDir=%@", ATRunDir()];
        NSString *doc = ATDaemon(@"doctor", &rc2);
        NSString *msg = [NSString stringWithFormat:
            @"runDir=%@\ndoctor rc=%d:\n%@", idOut, rc2, doc];
        return HttpResponse(200, @"text/plain; charset=utf-8", [msg dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/version"]) {
        int rc = 0;
        NSString *out = ATDaemon(@"version", &rc);
        return HttpResponse(200, @"text/plain; charset=utf-8", [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/probe"]) {
        int rc = 0;
        NSString *out = ATDaemon(@"probe", &rc);
        return HttpResponse(200, @"text/plain; charset=utf-8", [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/install"]) {
        NSString *name = qv[@"name"] ?: @"upload.ipa";
        if (!SafeToken(name) || ![name hasSuffix:@".ipa"]) name = @"upload.ipa";
        NSString *dest = [ATRunDir() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"up-%llu.ipa",
                           (unsigned long long)(CFAbsoluteTimeGetCurrent() * 1000)]];

        NSString *clenKey = nil;
        for (NSString *l in lines) {
            if ([[l lowercaseString] hasPrefix:@"content-length:"]) clenKey = l;
        }
        NSUInteger want = clenKey ? (NSUInteger)[[clenKey substringFromIndex:15]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue : 0;

        // 512KB 缓冲流式写盘：避免每包 1.4KB 就触发一次写盘 syscall，同时避免大包撞 jetsam 内存上限
        int wfd = open([dest fileSystemRepresentation], O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (wfd < 0) {
            return HttpResponse(500, @"text/plain", [@"无法创建临时文件" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        const size_t kBufCap = 512 * 1024;
        uint8_t *wbuf = (uint8_t *)malloc(kBufCap);
        size_t wlen = 0;
        NSUInteger got = 0;
        BOOL writeOK = (wbuf != NULL);

        if (writeOK && preBody.length > 0) {
            const uint8_t *p = (const uint8_t *)preBody.bytes;
            size_t left = preBody.length;
            while (left > 0) {
                ssize_t w = write(wfd, p, left);
                if (w <= 0) { if (errno == EINTR) continue; writeOK = NO; break; }
                p += w; left -= (size_t)w;
            }
            got = preBody.length;
        }
        while (writeOK && got < want) {
            size_t room = kBufCap - wlen;
            if (want - got < room) room = want - got;
            ssize_t n = read(fd, wbuf + wlen, room);
            if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
            wlen += (size_t)n;
            got += (NSUInteger)n;
            if (wlen >= kBufCap || got >= want) {
                const uint8_t *p = wbuf;
                size_t left = wlen;
                while (left > 0) {
                    ssize_t w = write(wfd, p, left);
                    if (w <= 0) { if (errno == EINTR) continue; writeOK = NO; break; }
                    p += w; left -= (size_t)w;
                }
                wlen = 0;
            }
        }
        if (writeOK && wlen > 0) {
            const uint8_t *p = wbuf;
            size_t left = wlen;
            while (left > 0) {
                ssize_t w = write(wfd, p, left);
                if (w <= 0) { if (errno == EINTR) continue; writeOK = NO; break; }
                p += w; left -= (size_t)w;
            }
        }
        free(wbuf);
        close(wfd);
        double upSec = CFAbsoluteTimeGetCurrent() - t0;
        if (upSec < 0.01) upSec = 0.01;
        if (got == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            return HttpResponse(400, @"text/plain", [@"空请求体" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        if (!writeOK || (want > 0 && got < want)) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            return HttpResponse(400, @"text/plain", [@"上传不完整" dataUsingEncoding:NSUTF8StringEncoding]);
        }

        CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
        int rc = 0;
        NSString *out = ATDaemonTimeout([NSString stringWithFormat:@"install %@", dest], 300, &rc);
        double instSec = CFAbsoluteTimeGetCurrent() - t1;
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        InvalidateProbeCache();
        NSString *summary = [NSString stringWithFormat:@"[上传 %.1f MB / %.1fs (%.1f MB/s) · 安装 %.1fs]\n%@",
                             (double)got / 1048576.0, upSec, ((double)got / 1048576.0) / upSec, instSec, out];
        // 184 = 安装成功，但包内含加密的嵌套二进制（上游非致命码）
        return HttpResponse((rc == 0 || rc == 184) ? 200 : 500, @"text/plain; charset=utf-8",
                            [summary dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/uninstall"]) {
        NSString *bid = qv[@"bid"] ?: @"";
        if (!SafeToken(bid)) {
            return HttpResponse(400, @"text/plain", [@"非法 bundle id" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        int rc = 0;
        NSString *out = ATDaemon([NSString stringWithFormat:@"uninstall %@", bid], &rc);
        InvalidateProbeCache();
        return HttpResponse(rc == 0 ? 200 : 500, @"text/plain; charset=utf-8",
                            [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/verify"]) {
        int rc = 0;
        NSString *out = ATDaemon(@"verify", &rc);
        return HttpResponse(200, @"text/plain; charset=utf-8", [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/selfupdate"]) {
        NSString *url = qv[@"url"] ?: @"";
        if (url.length < 10 || ![url hasPrefix:@"http"]) {
            return HttpResponse(400, @"text/plain; charset=utf-8",
                                [@"需要 ?url=http(s)://…/trollstore-lite-tv_x.y_….deb" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        int rc = 0;
        NSString *out = ATDaemon([NSString stringWithFormat:@"selfupdate %@", url], &rc);
        return HttpResponse(rc == 0 ? 200 : 500, @"text/plain; charset=utf-8",
                            [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/trust"]) {
        int rc = 0;
        NSString *out = ATDaemon(@"trust retrust", &rc);
        InvalidateProbeCache();
        return HttpResponse(200, @"text/plain; charset=utf-8", [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/userscripts.js"]) {
        NSString *js = UserscriptsBundleJS();
        return HttpResponse(200, @"application/javascript; charset=utf-8",
                            [js dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/userscripts/save"]) {
        NSString *name = qv[@"name"] ?: @"";
        if (!SafeScriptName(name)) {
            return HttpResponse(400, @"text/plain; charset=utf-8", [@"非法脚本名（只允许安全字符且以 .js 结尾）" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSString *clenKey = nil;
        for (NSString *l in lines) {
            if ([[l lowercaseString] hasPrefix:@"content-length:"]) clenKey = l;
        }
        NSUInteger want = clenKey ? (NSUInteger)[[clenKey substringFromIndex:15]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue : 0;
        if (want == 0 || want > 8 * 1024 * 1024) {
            return HttpResponse(400, @"text/plain; charset=utf-8", [@"脚本大小需在 1 B ~ 8 MB 之间" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSString *dir = UserscriptsDir();
        NSString *dest = [dir stringByAppendingPathComponent:name];
        int wfd = open(dest.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (wfd < 0) {
            return HttpResponse(500, @"text/plain; charset=utf-8", [@"无法写入脚本文件" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSUInteger got = 0;
        uint8_t buf[65536];
        if (preBody.length > 0) {
            size_t n0 = preBody.length > want ? want : preBody.length;
            write(wfd, preBody.bytes, n0);
            got = n0;
        }
        while (got < want) {
            size_t room = sizeof(buf);
            if (want - got < room) room = want - got;
            ssize_t n = read(fd, buf, room);
            if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
            if (write(wfd, buf, (size_t)n) != n) break;
            got += (NSUInteger)n;
        }
        close(wfd);
        if (got < want) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            return HttpResponse(400, @"text/plain; charset=utf-8", [@"脚本上传不完整" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        [[NSFileManager defaultManager] removeItemAtPath:[dest stringByAppendingString:@".disabled"] error:nil];
        return HttpResponse(200, @"text/plain; charset=utf-8",
                            [[NSString stringWithFormat:@"已保存脚本 %@ (%lu 字节)，重启 YouTube TVL 生效", name, (unsigned long)got]
                             dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/userscripts/toggle"]) {
        NSString *name = qv[@"name"] ?: @"";
        if (!SafeScriptName(name)) {
            return HttpResponse(400, @"text/plain; charset=utf-8", [@"非法脚本名" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSString *dir = UserscriptsDir();
        NSString *onP = [dir stringByAppendingPathComponent:name];
        NSString *offP = [onP stringByAppendingString:@".disabled"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:onP]) {
            [fm moveItemAtPath:onP toPath:offP error:nil];
            return HttpResponse(200, @"text/plain; charset=utf-8",
                                [[NSString stringWithFormat:@"已停用 %@", name] dataUsingEncoding:NSUTF8StringEncoding]);
        }
        if ([fm fileExistsAtPath:offP]) {
            [fm moveItemAtPath:offP toPath:onP error:nil];
            return HttpResponse(200, @"text/plain; charset=utf-8",
                                [[NSString stringWithFormat:@"已启用 %@", name] dataUsingEncoding:NSUTF8StringEncoding]);
        }
        return HttpResponse(404, @"text/plain; charset=utf-8", [@"找不到该脚本" dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/userscripts/delete"]) {
        NSString *name = qv[@"name"] ?: @"";
        if (!SafeScriptName(name)) {
            return HttpResponse(400, @"text/plain; charset=utf-8", [@"非法脚本名" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSString *dir = UserscriptsDir();
        NSString *onP = [dir stringByAppendingPathComponent:name];
        NSString *offP = [onP stringByAppendingString:@".disabled"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:onP error:nil];
        [fm removeItemAtPath:offP error:nil];
        return HttpResponse(200, @"text/plain; charset=utf-8",
                            [[NSString stringWithFormat:@"已删除 %@", name] dataUsingEncoding:NSUTF8StringEncoding]);
    }
    return HttpResponse(404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - 主循环

static void ServeConn(int fd);

static void *ConnThread(void *arg) {
    ServeConn((int)(intptr_t)arg);
    return NULL;
}

static void ServeConn(int fd) {
    // 半开/慢连接最多占用线程 30s，避免线程被无限拖住；加大接收缓冲 + 关 Nagle 提升局域网上传速率
    struct timeval tv = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int rcvbuf = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    NSUInteger clen = 0;
    NSMutableData *pre = [NSMutableData data];
    NSString *head = ReadHeaders(fd, &clen, pre);
    NSData *resp = head ? HandleRequest(head, pre, fd)
                        : HttpResponse(400, @"text/plain", [@"bad request" dataUsingEncoding:NSUTF8StringEncoding]);
    WriteAll(fd, resp);
    close(fd);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int port = 8787;
        if (argc > 1) port = atoi(argv[1]);

        signal(SIGPIPE, SIG_IGN);
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) { perror("socket"); return 1; }
        int one = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons((uint16_t)port);
        if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("bind"); return 1; }
        if (listen(s, 16) < 0) { perror("listen"); return 1; }

        fprintf(stdout, "tsltvweb listening on 0.0.0.0:%d\n", port);
        fflush(stdout);
        // 启动后后台预热应用列表缓存，避免首次访问 GET / 卡顿
        RefreshProbeAsync();

        for (;;) {
            struct sockaddr_in c;
            socklen_t cl = sizeof(c);
            int fd = accept(s, (struct sockaddr *)&c, &cl);
            if (fd < 0) { if (errno == EINTR) continue; break; }
            // tvOS SDK 禁用 fork；用 pthread 每连接一线程，避免一个大上传把整站堵住
            pthread_t th;
            if (pthread_create(&th, NULL, ConnThread, (void *)(intptr_t)fd) == 0) {
                pthread_detach(th);
            } else {
                ServeConn(fd);   // 线程创建失败就退回串行
            }
        }
        return 0;
    }
}

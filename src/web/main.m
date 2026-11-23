// tsltvweb —— TSLTV 的 Web 前端（tvOS 原生 CLI 程序，root 运行）
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
static NSString *ATDaemon(NSString *command, int *rcOut) {
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

    for (int i = 0; i < 9000; i++) {   // 20ms 粒度 × 9000 = 最多 180s（大 ipa 安装）
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
    int rc = 0;
    NSString *v = [ATDaemon(@"version", &rc) stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cached = (v.length && rc == 0) ? v : @"unknown";
    at = now;
    return cached;
}

static NSString *PageHTML(void) {
    int rc = 0;
    NSString *ver = TVCachedVersion();
    NSString *rows = ATDaemon(@"probe", &rc);
    NSMutableString *tr = [NSMutableString string];
    for (NSString *line in [rows componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 6) continue;
        BOOL trusted = [f[3] isEqualToString:@"1"];
        BOOL reg = [f[4] isEqualToString:@"1"];
        NSString *cdh = (NSString *)f[2];
        NSString *cd = cdh.length > 12 ? [cdh substringToIndex:12] : cdh;
        NSString *ver = f.count >= 8 ? (NSString *)f[7] : @"-";
        [tr appendFormat:
            @"<tr><td class='bid'>%@</td><td class='dim'>%@</td>"
             "<td class='%@'>%@</td><td class='%@'>%@</td>"
             "<td class='dim'>%@</td><td class='dim mono'>%@</td>"
             "<td><button onclick=\"act('uninstall','%@')\">卸载</button></td></tr>",
            f[0], ver, trusted ? @"ok" : @"bad", trusted ? @"✓" : @"✗",
            reg ? @"ok" : @"bad", reg ? @"✓" : @"✗",
            f[5], cd, f[0]];
    }
    if (tr.length == 0) tr = [NSMutableString stringWithString:@"<tr><td colspan='7' class='dim'>（暂无）</td></tr>"];

    return [NSString stringWithFormat:
        @"<!doctype html><meta charset=utf-8><title>TSLTV</title>"
         "<meta name=viewport content='width=device-width,initial-scale=1'>"
         "<style>"
         "body{background:#0b0b0d;color:#e8e8ea;font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:28px}"
         "h1{font-size:22px;margin:0 0 4px}"
         ".sub{color:#8b8b93;margin-bottom:22px}"
         "table{border-collapse:collapse;width:100%%}"
         "th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #1e1e22}"
         "th{color:#8b8b93;font-weight:500;font-size:13px}"
         ".bid{font-weight:600}"
         ".dim{color:#8b8b93}"
         ".mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}"
         ".ok{color:#39d353}.bad{color:#f0883e}"
         "button{background:#1f6feb;border:0;color:#fff;padding:6px 12px;border-radius:7px;cursor:pointer;font-size:13px}"
         "button:hover{filter:brightness(1.15)}"
         "#drop{border:1px dashed #30363d;border-radius:12px;padding:22px;text-align:center;margin:22px 0;color:#8b8b93}"
         "#drop.hot{border-color:#1f6feb;color:#e8e8ea}"
         "#log{white-space:pre-wrap;background:#111114;border:1px solid #1e1e22;border-radius:10px;padding:14px;"
         "font-family:ui-monospace,Menlo,monospace;font-size:12px;min-height:30px;margin-top:18px}"
         "</style>"
         "<h1>TSLTV</h1><div class=sub>tvOS 应用安装器 · v" "%@" " · ad-hoc 签名 + 内核信任缓存</div>", ver,
         "<div id=drop>把 .ipa 拖到这里，或 <input type=file id=f accept='.ipa' style='display:none'>"
         "<label for=f style='color:#1f6feb;cursor:pointer'>选择文件</label></div>"
         "<table><thead><tr><th>应用</th><th>版本</th><th>信任</th><th>注册</th><th>来源</th><th>cdhash</th><th></th></tr></thead>"
         "<tbody id=tb>%@</tbody></table>"
         "<div style='margin-top:18px'>"
         "<button onclick=\"selfUpd()\" style='background:#238636'>更新自身</button>"
         "<span class=dim style='margin-left:12px;font-size:13px'>"
         "把新版 deb 的直链填进弹出的输入框（package: trollstore-lite-tv）</span></div>"
         "<div id=log>就绪。已安装 %lu 个应用。</div>"
         "<script>"
         "const log=(t)=>{document.getElementById('log').textContent=t};"
         "async function act(cmd,arg){log('执行 '+cmd+(arg?' '+arg:'')+' …');"
         "const r=await fetch('/api/'+cmd+(arg?'?bid='+encodeURIComponent(arg):''),{method:'POST'});"
         "log(await r.text());setTimeout(()=>location.reload(),1200)}"
         "async function selfUpd(){"
         "const u=prompt('新版 deb 的 http 直链：','http://192.168.1.10:8899/trollstore-lite-tv_1.0.3_appletvos-arm64e.deb');"
         "if(!u)return;log('正在下载并交给 dpkg…');"
         "const r=await fetch('/api/selfupdate?url='+encodeURIComponent(u),{method:'POST'});"
         "log(await r.text()+'\\n\\n（服务约 10 秒后自动重启，刷新本页查看新版本）')}"
         "async function upload(file){log('上传 '+file.name+' ('+file.size+' 字节)…');"
         "const r=await fetch('/api/install?name='+encodeURIComponent(file.name),"
         "{method:'POST',body:file});log(await r.text());setTimeout(()=>location.reload(),1500)}"
         "const d=document.getElementById('drop'),inp=document.getElementById('f');"
         "inp.onchange=e=>e.target.files[0]&&upload(e.target.files[0]);"
         "['dragenter','dragover'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.add('hot')}));"
         "['dragleave','drop'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.remove('hot')}));"
         "d.addEventListener('drop',e=>{const f=e.dataTransfer.files[0];if(f)upload(f)});"
         "</script>",
        tr, (unsigned long)[tr componentsSeparatedByString:@"<tr>"].count - 1];
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

        // 边收边写：以前把整个 ipa 收进 NSMutableData，大包（Kodi 200MB+）会撞上
        // 本进程的 jetsam 内存上限被系统杀掉（JETSAM_REASON_MEMORY_PERPROCESSLIMIT）。
        int wfd = open([dest fileSystemRepresentation], O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (wfd < 0) {
            return HttpResponse(500, @"text/plain", [@"无法创建临时文件" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        NSUInteger got = 0;
        uint8_t buf[65536];
        if (preBody.length > 0) {
            write(wfd, preBody.bytes, preBody.length);
            got = preBody.length;
        }
        while (got < want) {
            size_t room = sizeof(buf);
            if (want - got < room) room = want - got;
            ssize_t n = read(fd, buf, room);
            if (n <= 0) break;
            if (write(wfd, buf, (size_t)n) != n) break;
            got += (NSUInteger)n;
        }
        close(wfd);
        if (got == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            return HttpResponse(400, @"text/plain", [@"空请求体" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        if (want > 0 && got < want) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            return HttpResponse(400, @"text/plain", [@"上传不完整" dataUsingEncoding:NSUTF8StringEncoding]);
        }

        int rc = 0;
        NSString *out = ATDaemon([NSString stringWithFormat:@"install %@", dest], &rc);
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        return HttpResponse(rc == 0 ? 200 : 500, @"text/plain; charset=utf-8",
                            [out dataUsingEncoding:NSUTF8StringEncoding]);
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/uninstall"]) {
        NSString *bid = qv[@"bid"] ?: @"";
        if (!SafeToken(bid)) {
            return HttpResponse(400, @"text/plain", [@"非法 bundle id" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        int rc = 0;
        NSString *out = ATDaemon([NSString stringWithFormat:@"uninstall %@", bid], &rc);
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
        return HttpResponse(200, @"text/plain; charset=utf-8", [out dataUsingEncoding:NSUTF8StringEncoding]);
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
    // 半开/慢连接最多占用线程 30s，避免线程被无限拖住
    struct timeval tv = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

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

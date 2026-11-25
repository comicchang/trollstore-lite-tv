// modinject —— 向 Mach-O 插入一条 LC_LOAD_DYLIB（tvOS 上的 mod 注入）
//
//   modinject <macho> <@executable_path/... 路径>
//
// 与 tools/inject_dylib.py 同一套逻辑，但跑在设备上（tsltv mods apply 调用）。
// 只改 load commands，签名会失效；调用方必须重新 ldid -S 并加入信任缓存。

#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>

static uint32_t align8(uint32_t n) { return (n + 7) & ~7u; }

static BOOL inject(NSString *bin, NSString *dylibPath, NSString **err) {
    // 只读打开源文件，修改后的内容原子写到同目录 .modtmp 再 rename 替换
    int fd = open(bin.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { *err = [NSString stringWithFormat:@"打不开文件: %s", strerror(errno)]; return NO; }
    off_t fsize = lseek(fd, 0, SEEK_END);
    if (fsize <= 0) { close(fd); *err = @"文件为空"; return NO; }
    lseek(fd, 0, SEEK_SET);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fsize];
    ssize_t got = read(fd, data.mutableBytes, (size_t)fsize);
    if (got != fsize) { close(fd); *err = @"读文件失败"; return NO; }

    uint8_t *p = data.mutableBytes;
    uint32_t magic = *(uint32_t *)p;
    BOOL is64;
    NSUInteger hdr;
    if (magic == MH_MAGIC_64) { is64 = YES; hdr = 32; }
    else if (magic == MH_MAGIC) { is64 = NO; hdr = 28; }
    else { *err = @"不是 Mach-O"; return NO; }

    struct mach_header_64 *mh = (struct mach_header_64 *)p;
    uint32_t ncmds = mh->ncmds, sizeofcmds = mh->sizeofcmds;

    // 已存在就不重复插
    NSUInteger off = hdr;
    uint64_t firstData = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command *)(p + off);
        if (lc->cmd == LC_LOAD_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            NSString *name = @((char *)lc + dc->dylib.name.offset);
            if ([name isEqualToString:dylibPath]) { *err = nil; return YES; }
        }
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (seg->fileoff > 0 && (firstData == 0 || seg->fileoff < firstData))
                firstData = seg->fileoff;
        }
        off += lc->cmdsize;
    }
    if (firstData == 0) firstData = hdr + sizeofcmds;

    NSData *utf8 = [dylibPath dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t need = align8((uint32_t)(24 + utf8.length + 1));
    if (firstData < hdr + sizeofcmds + need) {
        *err = [NSString stringWithFormat:@"头后空隙不足（需要 %u 字节）", need];
        return NO;
    }

    struct dylib_command dc;
    memset(&dc, 0, sizeof(dc));
    dc.cmd = LC_LOAD_DYLIB;   // 不要带 LC_REQ_DYLD，否则 otool/dyld 视为未知命令
    dc.cmdsize = need;
    dc.dylib.name.offset = 24;
    dc.dylib.timestamp = 2;
    dc.dylib.current_version = 0x10000;
    dc.dylib.compatibility_version = 0x10000;

    uint8_t *dst = p + hdr + sizeofcmds;
    memcpy(dst, &dc, sizeof(dc));
    memcpy(dst + 24, utf8.bytes, utf8.length);
    memset(dst + 24 + utf8.length, 0, need - 24 - utf8.length);

    mh->ncmds = ncmds + 1;
    mh->sizeofcmds = sizeofcmds + need;

    // 写到同目录临时文件再原子 rename：换新 inode，避免覆写正在/曾经执行过的 Mach-O 触发 EPERM 或 Darwin CS_VALID 失效
    close(fd);
    NSString *tmpPath = [bin stringByAppendingString:@".modtmp"];
    int wfd = open(tmpPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0755);
    if (wfd < 0) {
        *err = [NSString stringWithFormat:@"创建临时文件失败: %s", strerror(errno)];
        return NO;
    }
    const uint8_t *wp = (const uint8_t *)data.bytes;
    size_t left = (size_t)fsize;
    while (left > 0) {
        ssize_t w = write(wfd, wp, left);
        if (w <= 0) {
            if (errno == EINTR) continue;
            int e = errno;
            close(wfd);
            unlink(tmpPath.fileSystemRepresentation);
            *err = [NSString stringWithFormat:@"写回失败: %s", strerror(e)];
            return NO;
        }
        wp += w;
        left -= (size_t)w;
    }
    close(wfd);
    chmod(tmpPath.fileSystemRepresentation, 0755);
    if (rename(tmpPath.fileSystemRepresentation, bin.fileSystemRepresentation) != 0) {
        int e = errno;
        unlink(tmpPath.fileSystemRepresentation);
        *err = [NSString stringWithFormat:@"原子替换失败: %s", strerror(e)];
        return NO;
    }
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "用法: modinject <macho> <@executable_path/...>\n");
            return 2;
        }
        NSString *err = nil;
        if (!inject(@(argv[1]), @(argv[2]), &err)) {
            fprintf(stderr, "注入失败: %s\n", err.UTF8String ?: "未知");
            return 1;
        }
        printf("已注入 %s\n", argv[2]);
        return 0;
    }
}

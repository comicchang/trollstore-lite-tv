// machocheck —— 读 Mach-O 头，报出 platform / minos / cryptid
//
// 用法: machocheck <macho>
// 输出: platform=3 minos=17.0 cryptid=0
//
// 退出码: 0 正常 / 1 读不了或不是 Mach-O / 2 加密(cryptid!=0)
//
// 为什么需要它: 加密的 App Store 包（cryptid 1）在 tvOS 上启动即被内核杀，
// 与其让用户装完再看到闪退，不如在安装前就拒绝。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define LC_VERSION_MIN_TVOS 0x2F
#define LC_VERSION_MIN_IPHONEOS 0x25
#define LC_VERSION_MIN_MACOSX 0x24
#define LC_BUILD_VERSION 0x32
#define LC_ENCRYPTION_INFO 0x21
#define LC_ENCRYPTION_INFO_64 0x2C
#define MH_MAGIC_64 0xfeedfacf

static const char *plat_name(uint32_t p) {
    switch (p) {
        case 1: return "macOS";
        case 2: return "iOS";
        case 3: return "tvOS";
        case 4: return "watchOS";
        case 6: return "macCatalyst";
        case 7: return "iOSSim";
        case 8: return "tvOSSim";
        default: return "?";
    }
}

int main(int argc, char **argv) {
    char pathbuf[4096];
    if (argc < 2) {
        fprintf(stderr, "用法: machocheck <macho>\n");
        return 1;
    }
    // 本进程可能没有越狱的 vroot 映射：/var/... 实际落在 /rootfs/private/var/...
    static const char *prefixes[] = { "", "/rootfs/private", "/rootfs" };
    FILE *f = NULL;
    for (unsigned i = 0; i < sizeof(prefixes)/sizeof(prefixes[0]) && !f; i++) {
        snprintf(pathbuf, sizeof(pathbuf), "%s%s", prefixes[i], argv[1]);
        f = fopen(pathbuf, "rb");
    }
    if (!f) { perror("open"); return 1; }

    uint32_t magic = 0;
    if (fread(&magic, 4, 1, f) != 1) { fclose(f); return 1; }
    if (magic != MH_MAGIC_64) {
        fprintf(stderr, "不是 64 位小端 Mach-O（magic=0x%08x）\n", magic);
        fclose(f);
        return 1;
    }

    uint32_t ncmds = 0, sizeofcmds = 0;
    fseek(f, 16, SEEK_SET);
    if (fread(&ncmds, 4, 1, f) != 1 || fread(&sizeofcmds, 4, 1, f) != 1) {
        fclose(f);
        return 1;
    }

    uint32_t platform = 0, minos = 0, cryptid = 0;
    int have_platform = 0, have_crypt = 0;

    fseek(f, 32, SEEK_SET);
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        long pos = ftell(f);
        if (fread(&cmd, 4, 1, f) != 1 || fread(&cmdsize, 4, 1, f) != 1) break;
        if (cmdsize < 8) break;

        if (cmd == LC_BUILD_VERSION) {
            uint32_t p = 0, m = 0, s = 0;
            fseek(f, pos + 8, SEEK_SET);
            if (fread(&p, 4, 1, f) == 1 && fread(&m, 4, 1, f) == 1 && fread(&s, 4, 1, f) == 1) {
                platform = p; minos = m; have_platform = 1;
            }
        } else if (cmd == LC_VERSION_MIN_TVOS || cmd == LC_VERSION_MIN_IPHONEOS ||
                   cmd == LC_VERSION_MIN_MACOSX) {
            uint32_t m = 0, s = 0;
            fseek(f, pos + 8, SEEK_SET);
            if (fread(&m, 4, 1, f) == 1 && fread(&s, 4, 1, f) == 1) {
                if (!have_platform) {
                    platform = (cmd == LC_VERSION_MIN_TVOS) ? 3
                             : (cmd == LC_VERSION_MIN_IPHONEOS) ? 2 : 1;
                    minos = m;
                    have_platform = 1;
                }
            }
        } else if (cmd == LC_ENCRYPTION_INFO_64 || cmd == LC_ENCRYPTION_INFO) {
            uint32_t off = 0, size = 0, c = 0;
            fseek(f, pos + 8, SEEK_SET);
            if (fread(&off, 4, 1, f) == 1 && fread(&size, 4, 1, f) == 1 && fread(&c, 4, 1, f) == 1) {
                cryptid = c; have_crypt = 1;
            }
        }
        fseek(f, pos + cmdsize, SEEK_SET);
    }
    fclose(f);

    printf("platform=%u minos=%u.%u cryptid=%u",
           platform, minos >> 16, (minos >> 8) & 0xFF, cryptid);
    if (have_platform) printf(" (%s)", plat_name(platform));
    printf("\n");

    if (have_crypt && cryptid != 0) return 2;
    return 0;
}

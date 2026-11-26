// machoscan —— 快速扫描目录下的全部 Mach-O 文件（单进程，零 fork）
//
// 用法: machoscan <真实目录> [输出路径前缀]    列出全部 Mach-O
//       machoscan -e <真实目录>                只列出加密的 Mach-O（cryptid != 0）
//
// 为什么需要它：大应用（如 Kodi 含 12,000+ 文件）用 shell 逐文件 fork head+od+tr
// 耗时超过 10 分钟；用 C fts_open + read(4) 扫描全部 12,000+ 文件不到 0.1 秒。
//
// -e 与上游 TrollStore Lite 的加密检查对齐：Fat 二进制取首选 slice（arm64 优先），
// 其余格式（32 位、非 Mach-O、无法解析）一律按“未加密”处理，避免误杀。

#include <fcntl.h>
#include <fts.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FAT_MAGIC     0xcafebabeU
#define FAT_CIGAM     0xbebafecaU
#define MH_MAGIC      0xfeedfaceU
#define MH_MAGIC_64   0xfeedfacfU
#define CPU_TYPE_ARM64 0x0100000cU
#define LC_ENCRYPTION_INFO    0x21U
#define LC_ENCRYPTION_INFO_64 0x2cU

static uint32_t swap32(uint32_t v) {
    return ((v & 0xffU) << 24) | ((v & 0xff00U) << 8) |
           ((v >> 8) & 0xff00U) | (v >> 24);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int pread_full(int fd, void *buf, size_t len, off_t off) {
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = pread(fd, p, len, off);
        if (n <= 0) return -1;
        p += (size_t)n;
        off += n;
        len -= (size_t)n;
    }
    return 0;
}

// 读取 base 处的 Mach-O（thin）的 cryptid；返回 1 表示读到有效结构。
static int cryptid_at(int fd, off_t base, uint32_t *cryptid) {
    uint32_t magic = 0;
    if (pread_full(fd, &magic, 4, base) != 0) return 0;

    size_t header_size;
    if (magic == MH_MAGIC_64) header_size = 32;
    else if (magic == MH_MAGIC) header_size = 28;
    else return 0;

    uint8_t header[32];
    if (pread_full(fd, header, header_size, base) != 0) return 0;

    uint32_t ncmds, sizeofcmds;
    memcpy(&ncmds, header + 16, 4);
    memcpy(&sizeofcmds, header + 20, 4);
    if (sizeofcmds == 0 || sizeofcmds > (4U << 20)) return 0;

    uint8_t *cmds = (uint8_t *)malloc(sizeofcmds);
    if (!cmds) return 0;
    if (pread_full(fd, cmds, sizeofcmds, base + (off_t)header_size) != 0) {
        free(cmds);
        return 0;
    }

    int found = 0;
    size_t offset = 0;
    for (uint32_t i = 0; i < ncmds && offset + 8 <= sizeofcmds; i++) {
        uint32_t cmd, cmdsize;
        memcpy(&cmd, cmds + offset, 4);
        memcpy(&cmdsize, cmds + offset + 4, 4);
        if (cmdsize < 8 || offset + cmdsize > sizeofcmds) break;
        if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            if (cmdsize >= 20) {
                memcpy(cryptid, cmds + offset + 16, 4);
                found = 1;
            }
            break;
        }
        offset += cmdsize;
    }
    free(cmds);
    return found;
}

// Fat 二进制取首选 slice：arm64 > 第一个 slice。
static int cryptid_of_file(const char *path, uint32_t *cryptid) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;

    uint8_t head[8];
    int result = 0;
    if (pread_full(fd, head, 8, 0) == 0) {
        uint32_t magic;
        memcpy(&magic, head, 4);
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            // 文件字节 CA FE BA BE（宏 FAT_MAGIC）在 LE 主机上读成 FAT_CIGAM
            int be = (magic == FAT_CIGAM);
            uint32_t nfat = be ? read_be32(head + 4) : swap32(read_be32(head + 4));
            if (nfat > 0 && nfat <= 64) {
                off_t preferred = -1;
                off_t first = -1;
                for (uint32_t i = 0; i < nfat; i++) {
                    uint8_t arch[20];
                    if (pread_full(fd, arch, sizeof(arch), 8 + (off_t)i * 20) != 0) break;
                    uint32_t cputype = be ? read_be32(arch) : swap32(read_be32(arch));
                    uint32_t offset  = be ? read_be32(arch + 8) : swap32(read_be32(arch + 8));
                    if (first < 0) first = (off_t)offset;
                    if (cputype == CPU_TYPE_ARM64 && preferred < 0) preferred = (off_t)offset;
                }
                off_t slice = preferred >= 0 ? preferred : first;
                if (slice >= 0) result = cryptid_at(fd, slice, cryptid);
            }
        } else {
            result = cryptid_at(fd, 0, cryptid);
        }
    }
    close(fd);
    return result;
}

static int is_macho_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    close(fd);
    if (n != 4) return 0;
    // Little-endian & big-endian 32/64-bit Mach-O and Fat (universal) binaries
    return magic == 0xfeedfacfU || magic == 0xfeedfaceU ||
           magic == 0xcffaedfeU || magic == 0xcefaedfeU ||
           magic == 0xbebafecaU || magic == 0xcafebabeU;
}

int main(int argc, char **argv) {
    int encrypted_only = 0;
    if (argc >= 2 && strcmp(argv[1], "-e") == 0) {
        encrypted_only = 1;
        argv++;
        argc--;
    }
    if (argc < 2) {
        fprintf(stderr, "用法: machoscan [-e] <dir> [prefix]\n");
        return 2;
    }
    const char *root = argv[1];
    const char *prefix = (argc >= 3 && argv[2][0] != '\0') ? argv[2] : root;
    size_t root_len = strlen(root);
    while (root_len > 1 && root[root_len - 1] == '/') root_len--;

    char *paths[2] = { (char *)root, NULL };
    FTS *ftsp = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!ftsp) {
        perror("fts_open");
        return 1;
    }

    FTSENT *ent;
    while ((ent = fts_read(ftsp)) != NULL) {
        if (ent->fts_info != FTS_F) continue;
        if (!is_macho_file(ent->fts_path)) continue;
        if (encrypted_only) {
            uint32_t cryptid = 0;
            if (cryptid_of_file(ent->fts_path, &cryptid) && cryptid != 0) {
                printf("%s\n", ent->fts_path);
            }
            continue;
        }
        if (prefix != root && strncmp(ent->fts_path, root, root_len) == 0) {
            printf("%s%s\n", prefix, ent->fts_path + root_len);
        } else {
            printf("%s\n", ent->fts_path);
        }
    }
    fts_close(ftsp);
    return 0;
}

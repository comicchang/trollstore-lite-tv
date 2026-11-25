// hello-verify —— Stage 1 的最小 tvOS 可执行单元（纯 C，无 UI）。
//
// 后缀用 .m 只是为了和 probe-app.m 并列存放；内容是 C：打印 uid/gid/pid 后退出，
// 不写文件、不联网、不碰 Apple TV。
#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("uid=%ld gid=%ld pid=%ld\n", (long)getuid(), (long)getgid(), (long)getpid());
    printf("hello-verify ok\n");
    return 0;
}
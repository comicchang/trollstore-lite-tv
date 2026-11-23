// wake —— 往系统里注入一次 HID 按键事件，用于唤醒休眠/无显示输出的设备。
//
// 原理：IOHIDEventSystemClient（IOKit 私有接口）+ IOHIDEventCreateKeyboardEvent。
// 需要 entitlement：com.apple.private.hid.client.event-dispatch
//
// 用法: wake [usagePage] [usage]
//   默认 0x0C / 0xCD（Consumer / Play-Pause），对 Apple TV 是"唤醒并播放"级事件。

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

#include <dlfcn.h>

typedef IOHIDEventSystemClientRef (*CreateFn)(CFAllocatorRef, int, CFDictionaryRef);
typedef IOHIDEventRef (*EventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
typedef void (*DispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

int main(int argc, char *argv[]) {
    @autoreleasepool {
        uint32_t page = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : 0x0C;
        uint32_t usage = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 0xCD;

        // IOKit 在 tvOS SDK 里没有链接桩，只能在运行时 dlopen 取符号
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen IOKit 失败: %s\n", dlerror()); return 1; }
        CreateFn create = (CreateFn)dlsym(h, "IOHIDEventSystemClientCreateWithType");
        EventFn mkEvent = (EventFn)dlsym(h, "IOHIDEventCreateKeyboardEvent");
        DispatchFn dispatch = (DispatchFn)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        if (!create || !mkEvent || !dispatch) {
            fprintf(stderr, "dlsym 失败 create=%p event=%p dispatch=%p\n",
                    (void *)create, (void *)mkEvent, (void *)dispatch);
            return 1;
        }

        // type 1 = kIOHIDEventSystemClientTypeAdmin（可对系统派发事件）
        IOHIDEventSystemClientRef client = create(kCFAllocatorDefault, 1, NULL);
        if (!client) { client = create(kCFAllocatorDefault, 0, NULL); }
        if (!client) { fprintf(stderr, "创建 HID client 失败\n"); return 1; }

        IOHIDEventRef down = mkEvent(kCFAllocatorDefault, 0, page, usage, true, 0);
        IOHIDEventRef up = mkEvent(kCFAllocatorDefault, 0, page, usage, false, 0);
        if (!down || !up) {
            fprintf(stderr, "创建事件失败\n");
            return 1;
        }
        dispatch(client, down);
        usleep(50000);
        dispatch(client, up);
        printf("已派发 HID 事件 page=0x%X usage=0x%X\n", page, usage);
        return 0;
    }
}

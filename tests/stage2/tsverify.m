// tsverify —— Stage 2 隔离测试单元的原生容器部署 / 注册 / 清理助手。
//
// 只允许 com.tsltv.verify.* 命名空间与 /var/tmp/tsltv-verify-* 输入路径；
// 不写 /rootfs、不碰系统 App、不改生产应用与 installed.tsv。
//
// 用法（设备上以 root 运行，且二进制需经正常 ldid ad-hoc + trustcache 流程）：
//   tsverify deploy  /var/tmp/tsltv-verify-app/VerifyProbe.app com.tsltv.verify.probe
//   tsverify query   com.tsltv.verify.probe
//   tsverify cleanup com.tsltv.verify.probe
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kVerifyPrefix = @"com.tsltv.verify.";

static void fail(NSString *msg) {
    fprintf(stderr, "ERROR: %s\n", msg.UTF8String);
    fflush(stderr);
    exit(1);
}

static void out(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static BOOL isVerifyBundleId(NSString *bid) {
    return bid.length > kVerifyPrefix.length && [bid hasPrefix:kVerifyPrefix];
}

static void requireVerifyBundleId(NSString *bid) {
    if (!isVerifyBundleId(bid)) {
        fail([NSString stringWithFormat:@"拒绝非测试 Bundle ID：%@", bid]);
    }
}

static NSString *stripPrivateVar(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    // roothide / MCM 可能返回 /private/var/...，统一成 /var/... 再比较。
    if ([p hasPrefix:@"/private/var/"]) {
        return [p substringFromIndex:8];
    }
    return p;
}

static BOOL isTestStagePath(NSString *path) {
    NSString *p = stripPrivateVar(path);
    if ([p hasPrefix:@"/var/tmp/tsltv-verify-"]) return YES;
    // 从 shell 看是 /var/tmp/tsltv-verify-*，从 root helper 看是 jbroot 内的
    // /var/containers/Bundle/Application/.jbroot-*/var/tmp/tsltv-verify-*。
    NSRange jb = [p rangeOfString:@"/.jbroot-"];
    if (jb.location != NSNotFound) {
        NSString *tail = [p substringFromIndex:jb.location];
        if ([tail rangeOfString:@"/var/tmp/tsltv-verify-"].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL underPath(NSString *path, NSString *prefix) {
    if (path.length == 0 || prefix.length == 0) return NO;
    return [stripPrivateVar(path) hasPrefix:stripPrivateVar(prefix)];
}

// 私有框架可能位于 /System、/rootfs/System，或已被 dyld 预加载（按名字）。
static void *loadFramework(NSString *name) {
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/rootfs/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        name,
        [NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/rootfs/System/Library/Frameworks/%@.framework/%@", name, name],
    ];
    for (NSString *path in candidates) {
        void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
        if (h) {
            out(@"FRAMEWORK %@ ok=1 path=%@", name, path);
            return h;
        }
    }
    out(@"FRAMEWORK %@ ok=0", name);
    return NULL;
}

static Class resolveClass(NSString *clsName, NSString *framework) {
    Class c = NSClassFromString(clsName);
    if (c) return c;
    loadFramework(framework);
    return NSClassFromString(clsName);
}

static id callContainer(NSString *clsName, NSString *framework, NSString *bid,
                        BOOL create, NSError **error) {
    Class c = resolveClass(clsName, framework);
    if (!c) return nil;
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (![c respondsToSelector:sel]) return nil;
    typedef id (*Fn)(id, SEL, NSString *, BOOL, BOOL *, NSError **);
    return ((Fn)(void *)objc_msgSend)(c, sel, bid, create, NULL, error);
}

static NSString *containerPath(id container) {
    if (!container) return nil;
    NSURL *url = [container valueForKey:@"url"];
    return url.path;
}

static id workspace(void) {
    Class c = resolveClass(@"LSApplicationWorkspace", @"CoreServices");
    if (!c) return nil;
    SEL sel = NSSelectorFromString(@"defaultWorkspace");
    if (![c respondsToSelector:sel]) return nil;
    typedef id (*Fn)(id, SEL);
    return ((Fn)(void *)objc_msgSend)(c, sel);
}

static BOOL registerApp(NSString *bid, NSString *appPath, NSString *dataPath) {
    id ws = workspace();
    if (!ws) {
        out(@"REGISTER ok=0 reason=LSApplicationWorkspace-unavailable");
        return NO;
    }
    SEL sel = NSSelectorFromString(@"registerApplicationDictionary:");
    if (![ws respondsToSelector:sel]) {
        out(@"REGISTER ok=0 reason=registerApplicationDictionary-unavailable");
        return NO;
    }
    NSDictionary *env = @{
        @"CFFIXED_USER_HOME": dataPath,
        @"HOME": dataPath,
        @"TMPDIR": [dataPath stringByAppendingPathComponent:@"tmp"],
    };
    NSMutableDictionary *dict = [@{
        @"ApplicationType": @"System",
        @"CFBundleIdentifier": bid,
        @"CodeInfoIdentifier": bid,
        @"CompatibilityState": @0,
        @"IsContainerized": @YES,
        @"Container": dataPath,
        @"EnvironmentVariables": env,
        @"IsDeletable": @YES,
        @"Path": appPath,
        @"SignerOrganization": @"Apple Inc.",
        @"SignatureVersion": @132352,
        @"SignerIdentity": @"Apple iPhone OS Application Signing",
        @"IsAdHocSigned": @YES,
        @"LSInstallType": @1,
        @"HasMIDBasedSINF": @0,
        @"MissingSINF": @0,
        @"FamilyID": @0,
        @"IsOnDemandInstallCapable": @0,
        @"_LSBundlePlugins": @{},
    } mutableCopy];
    typedef BOOL (*Fn)(id, SEL, NSDictionary *);
    BOOL ok = ((Fn)(void *)objc_msgSend)(ws, sel, dict);
    out(@"REGISTER bid=%@ ok=%d path=%@ container=%@", bid, ok ? 1 : 0, appPath, dataPath);
    return ok;
}

static BOOL unregisterApp(NSString *appPath) {
    id ws = workspace();
    if (!ws) return NO;
    SEL sel = NSSelectorFromString(@"unregisterApplication:");
    if (![ws respondsToSelector:sel]) return NO;
    typedef BOOL (*Fn)(id, SEL, NSURL *);
    return ((Fn)(void *)objc_msgSend)(ws, sel, [NSURL fileURLWithPath:appPath]);
}

static void chmodTree(NSString *root, NSString *executableName) {
    NSFileManager *fm = [NSFileManager defaultManager];
    chmod(root.fileSystemRepresentation, 0755);
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:p isDirectory:&isDir];
        mode_t mode = isDir ? 0755 : 0644;
        if (!isDir && [rel isEqualToString:executableName]) mode = 0755;
        chmod(p.fileSystemRepresentation, mode);
    }
}

static int cmdDeploy(NSString *srcArg, NSString *bidArg) {
    requireVerifyBundleId(bidArg);
    NSString *src = srcArg.stringByStandardizingPath;
    if (![src.pathExtension isEqualToString:@"app"]) {
        fail([NSString stringWithFormat:@"输入不是 .app：%@", src]);
    }
    if (!isTestStagePath(src)) {
        fail([NSString stringWithFormat:@"输入路径不在测试暂存区：%@", src]);
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [src stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) {
        fail([NSString stringWithFormat:@"读不到 Info.plist：%@", src]);
    }
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![bid isEqualToString:bidArg]) {
        fail([NSString stringWithFormat:@"Bundle ID 不一致：info=%@ arg=%@", bid, bidArg]);
    }
    NSString *exe = info[@"CFBundleExecutable"];
    if (exe.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:[src stringByAppendingPathComponent:exe]]) {
        fail([NSString stringWithFormat:@"主可执行缺失：%@", exe]);
    }

    NSError *error = nil;
    id appContainer = callContainer(@"MCMAppContainer", @"MobileContainerManager", bid, YES, &error);
    if (!appContainer) {
        fail([NSString stringWithFormat:@"MCMAppContainer 创建失败：%@", error.localizedDescription]);
    }
    NSString *appRoot = containerPath(appContainer);
    if (!underPath(appRoot, @"/var/containers/Bundle/Application/")) {
        fail([NSString stringWithFormat:@"MCMAppContainer 路径越界：%@", appRoot]);
    }

    id dataContainer = callContainer(@"MCMAppDataContainer", @"MobileContainerManager", bid, YES, &error);
    if (!dataContainer) {
        fail([NSString stringWithFormat:@"MCMAppDataContainer 创建失败：%@", error.localizedDescription]);
    }
    NSString *dataRoot = containerPath(dataContainer);
    if (!underPath(dataRoot, @"/var/mobile/Containers/Data/Application/")) {
        fail([NSString stringWithFormat:@"MCMAppDataContainer 路径越界：%@", dataRoot]);
    }

    NSString *target = [appRoot stringByAppendingPathComponent:src.lastPathComponent];
    if (!underPath(target, appRoot)) {
        fail([NSString stringWithFormat:@"目标路径越界：%@", target]);
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:target]) {
        if (![fm removeItemAtPath:target error:&error]) {
            fail([NSString stringWithFormat:@"清理旧测试包失败：%@", error.localizedDescription]);
        }
    }
    if (![fm copyItemAtPath:src toPath:target error:&error]) {
        fail([NSString stringWithFormat:@"复制测试包失败：%@", error.localizedDescription]);
    }
    chmodTree(target, exe);

    BOOL ok = registerApp(bid, target, dataRoot);
    out(@"DEPLOY bid=%@ ok=%d app_container=%@ app_bundle=%@ data_container=%@",
        bid, ok ? 1 : 0, appRoot, target, dataRoot);
    return ok ? 0 : 1;
}

static int cmdQuery(NSString *bid) {
    requireVerifyBundleId(bid);
    Class proxyClass = resolveClass(@"LSApplicationProxy", @"CoreServices");
    if (!proxyClass) {
        out(@"QUERY bid=%@ installed=0 reason=LSApplicationProxy-unavailable", bid);
        return 2;
    }
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:sel]) {
        out(@"QUERY bid=%@ installed=0 reason=applicationProxyForIdentifier-unavailable", bid);
        return 2;
    }
    typedef id (*Fn)(id, SEL, NSString *);
    id proxy = ((Fn)(void *)objc_msgSend)(proxyClass, sel, bid);
    if (!proxy) {
        out(@"QUERY bid=%@ installed=0", bid);
        return 2;
    }
    NSNumber *installed = [proxy valueForKey:@"installed"];
    NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
    NSString *type = [proxy valueForKey:@"applicationType"];
    out(@"QUERY bid=%@ installed=%d type=%@ path=%@", bid,
        installed.boolValue ? 1 : 0, type ?: @"(nil)", bundleURL.path ?: @"(nil)");
    return installed.boolValue ? 0 : 2;
}

static int cmdCleanup(NSString *bid) {
    requireVerifyBundleId(bid);
    Class proxyClass = resolveClass(@"LSApplicationProxy", @"CoreServices");
    NSString *appPath = nil;
    if (proxyClass) {
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if ([proxyClass respondsToSelector:sel]) {
            typedef id (*Fn)(id, SEL, NSString *);
            id proxy = ((Fn)(void *)objc_msgSend)(proxyClass, sel, bid);
            NSURL *u = [proxy valueForKey:@"bundleURL"];
            appPath = u.path;
        }
    }

    NSError *error = nil;
    id appContainer = callContainer(@"MCMAppContainer", @"MobileContainerManager", bid, NO, &error);
    id dataContainer = callContainer(@"MCMAppDataContainer", @"MobileContainerManager", bid, NO, &error);
    NSString *appRoot = containerPath(appContainer);
    NSString *dataRoot = containerPath(dataContainer);

    if (appPath.length == 0 && appRoot.length > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *item in [fm contentsOfDirectoryAtPath:appRoot error:nil]) {
            if ([item.pathExtension isEqualToString:@"app"]) {
                appPath = [appRoot stringByAppendingPathComponent:item];
                break;
            }
        }
    }

    BOOL unregistered = NO;
    if (appPath.length > 0 && underPath(appPath, @"/var/containers/Bundle/Application/")) {
        unregistered = unregisterApp(appPath);
    }
    out(@"UNREGISTER bid=%@ ok=%d path=%@", bid, unregistered ? 1 : 0, appPath ?: @"(nil)");

    BOOL deleted = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (appRoot.length > 0 && underPath(appRoot, @"/var/containers/Bundle/Application/")) {
        if ([fm fileExistsAtPath:appRoot] && ![fm removeItemAtPath:appRoot error:&error]) {
            out(@"REMOVE app_container=%@ ok=0 error=%@", appRoot, error.localizedDescription);
            deleted = NO;
        } else {
            out(@"REMOVE app_container=%@ ok=1", appRoot);
        }
    }
    if (dataRoot.length > 0 && underPath(dataRoot, @"/var/mobile/Containers/Data/Application/")) {
        if ([fm fileExistsAtPath:dataRoot] && ![fm removeItemAtPath:dataRoot error:&error]) {
            out(@"REMOVE data_container=%@ ok=0 error=%@", dataRoot, error.localizedDescription);
            deleted = NO;
        } else {
            out(@"REMOVE data_container=%@ ok=1", dataRoot);
        }
    }

    out(@"CLEANUP bid=%@ unregister=%d deleted=%d", bid, unregistered ? 1 : 0, deleted ? 1 : 0);
    return deleted ? 0 : 1;
}

static int cmdSelftest(NSString *appPath) {
    NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:appPath isDirectory:&isDir];
    out(@"SELFTEST app=%@ exists=%d isDir=%d plist=%@", appPath, exists ? 1 : 0, isDir ? 1 : 0, plistPath);
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObjects:
        appPath,
        [@"/private" stringByAppendingString:appPath],
        [@"/rootfs/private" stringByAppendingString:appPath],
        nil];
    // jbroot 名称随设备/越狱版本变化，禁止硬编码哈希；这里运行时枚举。
    NSString *appBase = @"/var/containers/Bundle/Application";
    for (NSString *entry in [fm contentsOfDirectoryAtPath:appBase error:nil]) {
        if (![entry hasPrefix:@".jbroot-"]) continue;
        [candidates addObject:[NSString stringWithFormat:@"%@/%@%@", appBase, entry, appPath]];
        [candidates addObject:[NSString stringWithFormat:@"/private%@/%@%@", appBase, entry, appPath]];
        [candidates addObject:[NSString stringWithFormat:@"/rootfs/private%@/%@%@", appBase, entry, appPath]];
    }
    for (NSString *candidate in candidates) {
        BOOL cDir = NO;
        BOOL cExists = [fm fileExistsAtPath:candidate isDirectory:&cDir];
        out(@"SELFTEST candidate=%@ exists=%d isDir=%d", candidate, cExists ? 1 : 0, cDir ? 1 : 0);
    }
    char resolved[PATH_MAX] = {0};
    out(@"SELFTEST realpath(/var/tmp)=%s", realpath("/var/tmp", resolved) ? resolved : "(fail)");
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    out(@"SELFTEST data_len=%lu", (unsigned long)data.length);
    if (data) {
        NSError *error = nil;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:&error];
        out(@"SELFTEST plist_class=%@ error=%@", plist ? NSStringFromClass([plist class]) : @"(nil)",
            error.localizedDescription ?: @"(none)");
    }
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    out(@"SELFTEST dict=%@ keys=%lu", dict ? @"ok" : @"(nil)", dict ? (unsigned long)dict.count : 0UL);
    return dict ? 0 : 1;
}

static void usage(void) {
    out(@"用法:");
    out(@"  tsverify deploy  /var/tmp/tsltv-verify-app/VerifyProbe.app com.tsltv.verify.probe");
    out(@"  tsverify query   com.tsltv.verify.probe");
    out(@"  tsverify cleanup com.tsltv.verify.probe");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (geteuid() != 0) fail(@"必须以 root 运行");
        if (argc < 3) {
            usage();
            return 2;
        }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        NSString *arg = [NSString stringWithUTF8String:argv[2]];
        if ([cmd isEqualToString:@"deploy"]) {
            if (argc < 4) {
                usage();
                return 2;
            }
            return cmdDeploy(arg, [NSString stringWithUTF8String:argv[3]]);
        }
        if ([cmd isEqualToString:@"query"]) return cmdQuery(arg);
        if ([cmd isEqualToString:@"cleanup"]) return cmdCleanup(arg);
        if ([cmd isEqualToString:@"selftest"]) return cmdSelftest(arg);
        usage();
        return 2;
    }
}
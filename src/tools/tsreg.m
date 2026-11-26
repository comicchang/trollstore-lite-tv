// tsreg —— tvOS 原生容器 + LaunchServices 注册（洁净室原创实现，纯 MIT）
//
// 行为契约对齐 opa334/TrollStore RootHelper 的安装/注册语义（未复制其 BSD-4-Clause 源码）：
//   - 按 entitlements 决定容器化：no-container / container-required=false → 不容器化；
//     container-required 为字符串 → 自定义容器 id；其余 → 以 bundle id 为容器 id；
//   - 为 app 与 PlugIns/*.appex 建 MCM 数据容器，写入 IsContainerized / Container /
//     EnvironmentVariables，并附带 Entitlements、插件表、App Group 容器等字段；
//   - 注册类型默认 System（tvOS 无 AppSync，等价上游 forceSystem）；
//   - 卸载时删除数据容器、插件容器，App Group 容器只在没有其他应用引用时删除，再注销注册。
//
// 私有 API 全部运行时解析（dlopen + NSClassFromString），不使用 -undefined dynamic_lookup。
// 系统应用判定（RootHide 陷阱）：只有密封卷 /rootfs/Applications、/System/Applications
// （或 /rootfs 下真实存在的同名 app）才算系统应用；包含 .jbroot- 的路径、或位于
// installed.tsv 的 bundle id 一律是自装应用，绝不当作不可变系统应用。
//
// 用法:
//   tsreg patch-info <app>              写入 SBAppUsesLocalNotifications，剥离系统应用占用的 URL scheme
//   tsreg register <app> [--user]       建容器并注册（默认 System）
//   tsreg unregister <app|bundle-id>    删除容器（App Group 引用计数保护）并注销注册
//   tsreg query <bundle-id>             输出 installed=/type=/path=/containerized=/data_container=
// 退出码: 0 成功 / 2 用法 / 3 系统应用 / 4 Info.plist 或主可执行缺失 / 5 注册失败 / 6 注销失败 / 7 补丁失败

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/stat.h>
#import <unistd.h>
#include <stdio.h>
#include <string.h>

enum {
	TSREG_OK = 0,
	TSREG_USAGE = 2,
	TSREG_IMMUTABLE = 3,
	TSREG_INFO = 4,
	TSREG_REGISTER_FAILED = 5,
	TSREG_UNREGISTER_FAILED = 6,
	TSREG_PATCH_FAILED = 7,
};

static void logmsg(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	fprintf(stderr, "tsreg: %s\n", line.UTF8String);
}

static NSFileManager *FM(void) { return [NSFileManager defaultManager]; }

static id msg0(id obj, NSString *name)
{
	SEL sel = NSSelectorFromString(name);
	if (!obj || ![obj respondsToSelector:sel]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static BOOL msgBool(id obj, NSString *name, BOOL fallback)
{
	SEL sel = NSSelectorFromString(name);
	if (!obj || ![obj respondsToSelector:sel]) return fallback;
	return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id clsMsg0(Class cls, NSString *name)
{
	SEL sel = NSSelectorFromString(name);
	if (!cls || ![cls respondsToSelector:sel]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static id clsMsg1(Class cls, NSString *name, id arg)
{
	SEL sel = NSSelectorFromString(name);
	if (!cls || ![cls respondsToSelector:sel]) return nil;
	return ((id (*)(id, SEL, id))objc_msgSend)((id)cls, sel, arg);
}

// 路径统一：去掉 /private 前缀，便于与 installed.tsv、/rootfs 判断对齐
static NSString *normalizePath(NSString *path)
{
	NSString *p = path.stringByStandardizingPath;
	if ([p hasPrefix:@"/private/var/"]) return [p substringFromIndex:8];
	if ([p hasPrefix:@"/private/Applications/"]) return [p substringFromIndex:8];
	if ([p hasPrefix:@"/private/System/"]) return [p substringFromIndex:8];
	return p;
}

static NSString *resolveAppPath(NSString *arg)
{
	NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObjects:
		arg,
		[@"/private" stringByAppendingString:arg],
		[@"/rootfs" stringByAppendingString:arg],
		nil];
	// RootHide：/Applications/Foo.app 的实体也可能在 .jbroot-*/Applications/Foo.app
	if ([arg hasPrefix:@"/"]) {
		for (NSString *base in @[@"/var/containers/Bundle/Application", @"/private/var/containers/Bundle/Application"]) {
			for (NSString *entry in [FM() contentsOfDirectoryAtPath:base error:nil]) {
				if (![entry hasPrefix:@".jbroot-"]) continue;
				[candidates addObject:[NSString stringWithFormat:@"%@/%@%@", base, entry, arg]];
			}
		}
	}
	for (NSString *cand in candidates) {
		BOOL isDir = NO;
		if ([FM() fileExistsAtPath:cand isDirectory:&isDir] && isDir) return cand;
	}
	return nil;
}

// ---------- installed.tsv（自装应用清单）----------

static NSSet<NSString *> *managedBundleIds(void)
{
	NSMutableSet *ids = [NSMutableSet set];
	NSMutableArray<NSString *> *files = [NSMutableArray arrayWithObject:@"/usr/libexec/tsltv/installed.tsv"];
	for (NSString *base in @[@"/var/containers/Bundle/Application", @"/private/var/containers/Bundle/Application"]) {
		for (NSString *entry in [FM() contentsOfDirectoryAtPath:base error:nil]) {
			if (![entry hasPrefix:@".jbroot-"]) continue;
			[files addObject:[NSString stringWithFormat:@"%@/%@/usr/libexec/tsltv/installed.tsv", base, entry]];
		}
	}
	for (NSString *file in files) {
		NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
		if (!text.length) continue;
		for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
			NSString *bid = [line componentsSeparatedByString:@"\t"].firstObject;
			if (bid.length) [ids addObject:bid.lowercaseString];
		}
	}
	return ids;
}

// ---------- 系统应用判定（避免把 RootHide 的 /Applications 自装应用误判为系统）----------

static BOOL isSystemBundlePath(NSString *path)
{
	if (!path.length) return NO;
	NSString *p = normalizePath(path);
	// RootHide jbroot 里的密封根：<jbroot>/rootfs/Applications/...（tsreg 进程常见视图）
	NSRange jb = [p rangeOfString:@".jbroot-"];
	if (jb.location != NSNotFound) {
		NSString *tail = [p substringFromIndex:jb.location];
		if ([tail rangeOfString:@"/rootfs/Applications/"].location != NSNotFound ||
		    [tail rangeOfString:@"/rootfs/System/Applications/"].location != NSNotFound ||
		    [tail rangeOfString:@"/System/Applications/"].location != NSNotFound) return YES;
		return NO;
	}
	if ([p hasPrefix:@"/rootfs/Applications/"] || [p hasPrefix:@"/System/Applications/"]) return YES;
	// LS 可能回报越狱前的路径（/Applications/Foo.app）；只要密封卷里真有同名 app 就是系统应用
	return [FM() fileExistsAtPath:[@"/rootfs" stringByAppendingString:p]];
}

static BOOL isRemovableSystemApp(NSString *bid)
{
	if (!bid.length) return NO;
	return [FM() fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:bid]]
		|| [FM() fileExistsAtPath:[@"/rootfs/System/Library/AppSignatures" stringByAppendingPathComponent:bid]];
}

// ---------- 私有框架与私有类解析 ----------

static void *loadFramework(NSString *name)
{
	NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:name];
	NSMutableArray<NSString *> *bases = [NSMutableArray arrayWithObjects:
		@"/System/Library/PrivateFrameworks",
		@"/System/Library/Frameworks",
		@"/rootfs/System/Library/PrivateFrameworks",
		@"/rootfs/System/Library/Frameworks",
		nil];
	NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:name];
	if ([name isEqualToString:@"CoreServices"]) [names addObject:@"MobileCoreServices"];
	for (NSString *base in bases) {
		for (NSString *n in names) {
			[paths addObject:[NSString stringWithFormat:@"%@/%@.framework/%@", base, n, n]];
		}
	}
	for (NSString *path in paths) {
		void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
		if (h) return h;
	}
	return NULL;
}

static Class resolveClass(NSString *clsName, NSString *framework)
{
	Class cls = NSClassFromString(clsName);
	if (cls) return cls;
	loadFramework(framework);
	return NSClassFromString(clsName);
}

static id containerFor(NSString *clsName, NSString *framework, NSString *ident, BOOL create)
{
	Class cls = resolveClass(clsName, framework);
	SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
	if (!cls || ![cls respondsToSelector:sel]) return nil;
	NSError *error = nil;
	typedef id (*Fn)(id, SEL, NSString *, BOOL, BOOL *, NSError **);
	id container = ((Fn)(void *)objc_msgSend)(cls, sel, ident, create, NULL, &error);
	if (!container && error && create) logmsg(@"%@(%@) 失败: %@", clsName, ident, error.localizedDescription);
	return container;
}

static NSString *containerPath(id container)
{
	if (!container) return nil;
	id url = msg0(container, @"url");
	if ([url isKindOfClass:[NSURL class]]) return [(NSURL *)url path];
	return nil;
}

// ---------- LaunchServices ----------

static id lsWorkspace(void)
{
	Class cls = resolveClass(@"LSApplicationWorkspace", @"CoreServices");
	return cls ? clsMsg0(cls, @"defaultWorkspace") : nil;
}

static id lsProxy(NSString *bid)
{
	Class cls = resolveClass(@"LSApplicationProxy", @"CoreServices");
	return cls ? clsMsg1(cls, @"applicationProxyForIdentifier:", bid) : nil;
}

static NSArray *lsAllProxies(void)
{
	Class enumCls = resolveClass(@"LSEnumerator", @"CoreServices");
	if (enumCls) {
		SEL sel = NSSelectorFromString(@"enumeratorForApplicationProxiesWithOptions:");
		if ([enumCls respondsToSelector:sel]) {
			typedef id (*Fn)(id, SEL, NSUInteger);
			id enumerator = ((Fn)(void *)objc_msgSend)(enumCls, sel, (NSUInteger)0);
			if (enumerator) {
				NSMutableArray *out = [NSMutableArray new];
				id proxy;
				while ((proxy = msg0(enumerator, @"nextObject"))) [out addObject:proxy];
				return out;
			}
		}
	}
	id ws = lsWorkspace();
	id all = msg0(ws, @"allApplications");
	return [all isKindOfClass:[NSArray class]] ? all : @[];
}

static id proxyValue(id proxy, NSString *key)
{
	if (!proxy) return nil;
	SEL sel = NSSelectorFromString(key);
	if ([proxy respondsToSelector:sel]) {
		return ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
	}
	@try {
		return [proxy valueForKey:key];
	} @catch (NSException *e) {
		return nil;
	}
}

static NSString *proxyBundlePath(id proxy)
{
	id url = proxyValue(proxy, @"bundleURL");
	return [url isKindOfClass:[NSURL class]] ? [(NSURL *)url path] : nil;
}

static BOOL proxyInstalled(id proxy)
{
	NSNumber *installed = proxyValue(proxy, @"installed");
	return installed ? installed.boolValue : YES;
}

static NSSet<NSString *> *systemBundleIds(NSSet<NSString *> *managed)
{
	NSMutableSet *ids = [NSMutableSet set];
	for (id proxy in lsAllProxies()) {
		if (!proxyInstalled(proxy)) continue;
		NSString *bid = proxyValue(proxy, @"bundleIdentifier");
		if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
		if ([managed containsObject:bid.lowercaseString]) continue;
		if (isSystemBundlePath(proxyBundlePath(proxy)) || isRemovableSystemApp(bid)) {
			[ids addObject:bid.lowercaseString];
		}
	}
	// LS proxy 的路径在 RootHide 下可能不可见；直接扫密封卷补充（只读）
	NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObjects:
		@"/rootfs/Applications", @"/System/Applications", nil];
	for (NSString *base in @[@"/var/containers/Bundle/Application", @"/private/var/containers/Bundle/Application"]) {
		for (NSString *entry in [FM() contentsOfDirectoryAtPath:base error:nil]) {
			if (![entry hasPrefix:@".jbroot-"]) continue;
			[roots addObject:[NSString stringWithFormat:@"%@/%@/rootfs/Applications", base, entry]];
			[roots addObject:[NSString stringWithFormat:@"%@/%@/System/Applications", base, entry]];
		}
	}
	for (NSString *root in roots) {
		for (NSString *name in [FM() contentsOfDirectoryAtPath:root error:nil]) {
			if (![name hasSuffix:@".app"]) continue;
			NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
				[NSString stringWithFormat:@"%@/%@/Info.plist", root, name]];
			NSString *bid = appInfo[@"CFBundleIdentifier"];
			if ([bid isKindOfClass:[NSString class]] && bid.length &&
			    ![managed containsObject:bid.lowercaseString]) {
				[ids addObject:bid.lowercaseString];
			}
		}
	}
	return ids;
}

static NSSet<NSString *> *systemURLSchemes(NSSet<NSString *> *managed)
{
	NSMutableSet *schemes = [NSMutableSet set];
	for (id proxy in lsAllProxies()) {
		NSString *bid = proxyValue(proxy, @"bundleIdentifier");
		if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
		if ([managed containsObject:bid.lowercaseString]) continue;
		BOOL system = isSystemBundlePath(proxyBundlePath(proxy)) || isRemovableSystemApp(bid);
		if (!system) continue;
		NSArray *claimed = proxyValue(proxy, @"claimedURLSchemes");
		if (![claimed isKindOfClass:[NSArray class]]) continue;
		for (id scheme in claimed) {
			if ([scheme isKindOfClass:[NSString class]] && [scheme length]) {
				[schemes addObject:[scheme lowercaseString]];
			}
		}
	}
	return schemes;
}

// ---------- entitlements 解析（从已签名 Mach-O 的 code signature 里取）----------

static uint32_t readBE32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint32_t readLE32(const uint8_t *p)
{
	return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[0];
}

static uint64_t readBE64(const uint8_t *p)
{
	return ((uint64_t)readBE32(p) << 32) | (uint64_t)readBE32(p + 4);
}

// 从（可能是 fat）文件里选首选 slice：优先 arm64
static BOOL pickSlice(NSData *data, const uint8_t **sliceOut, size_t *lenOut)
{
	const uint8_t *base = (const uint8_t *)data.bytes;
	size_t total = (size_t)data.length;
	if (total < 8) return NO;
	uint32_t magic = readBE32(base);
	if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
		BOOL is64 = (magic == FAT_MAGIC_64);
		uint32_t count = readBE32(base + 4);
		if (count == 0 || count > 64) return NO;
		const uint8_t *best = NULL;
		size_t bestLen = 0;
		BOOL bestArm = NO;
		NSUInteger entrySize = is64 ? 32 : 20;
		for (uint32_t i = 0; i < count; i++) {
			const uint8_t *arch = base + 8 + (NSUInteger)i * entrySize + 0;
			if ((size_t)(arch - base) + entrySize > total) break;
			uint32_t cputype = readBE32(arch);
			uint64_t off = is64 ? readBE64(arch + 8) : (uint64_t)readBE32(arch + 8);
			uint64_t size = is64 ? readBE64(arch + 16) : (uint64_t)readBE32(arch + 12);
			if (off > total || size > total || off + size > total) continue;
			BOOL arm = (cputype == CPU_TYPE_ARM64);
			if (arm || !best) {
				if (!bestArm || arm) {
					best = base + off;
					bestLen = (size_t)size;
					bestArm = arm;
				}
			}
		}
		if (!best) return NO;
		*sliceOut = best;
		*lenOut = bestLen;
		return YES;
	}
	uint32_t le = readLE32(base);
	if (le == MH_MAGIC_64 || le == MH_MAGIC) {
		*sliceOut = base;
		*lenOut = total;
		return YES;
	}
	return NO;
}

static NSDictionary *entitlementsFromMachO(NSString *path)
{
	NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
	if (!data) data = [NSData dataWithContentsOfFile:path];
	if (!data) return nil;
	const uint8_t *slice = NULL;
	size_t sliceLen = 0;
	if (!pickSlice(data, &slice, &sliceLen)) return nil;

	uint32_t magic = readLE32(slice);
	uint32_t headerSize = (magic == MH_MAGIC_64) ? 32 : ((magic == MH_MAGIC) ? 28 : 0);
	if (!headerSize || sliceLen < headerSize) return nil;
	uint32_t ncmds = readLE32(slice + 16);
	uint32_t sizeofcmds = readLE32(slice + 20);
	if ((size_t)headerSize + sizeofcmds > sliceLen) return nil;

	const uint8_t *cmd = slice + headerSize;
	const uint8_t *cmdEnd = cmd + sizeofcmds;
	uint32_t sigOff = 0, sigLen = 0;
	for (uint32_t i = 0; i < ncmds && cmd + 8 <= cmdEnd; i++) {
		uint32_t c = readLE32(cmd);
		uint32_t csize = readLE32(cmd + 4);
		if (csize < 8) break;
		if (c == LC_CODE_SIGNATURE && csize >= 16) {
			sigOff = readLE32(cmd + 8);
			sigLen = readLE32(cmd + 12);
			break;
		}
		cmd += csize;
	}
	if (!sigOff || sigLen < 12 || (size_t)sigOff + sigLen > sliceLen) return nil;

	const uint8_t *sig = slice + sigOff;
	if (readBE32(sig) != 0xfade0cc0) return nil; // SuperBlob
	uint32_t count = readBE32(sig + 8);
	if (count > 128 || (size_t)12 + (size_t)count * 8 > sigLen) return nil;
	for (uint32_t i = 0; i < count; i++) {
		const uint8_t *entry = sig + 12 + (size_t)i * 8;
		uint32_t type = readBE32(entry);
		uint32_t offset = readBE32(entry + 4);
		if (type != 5) continue; // CSSLOT_ENTITLEMENTS
		if ((size_t)offset + 8 > sigLen) return nil;
		const uint8_t *blob = sig + offset;
		uint32_t blobMagic = readBE32(blob);
		uint32_t blobLen = readBE32(blob + 4);
		if (blobMagic != 0xfade7171) return nil; // 非 XML entitlements（DER）
		if (blobLen < 8 || (size_t)offset + blobLen > sigLen) return nil;
		NSData *plist = [NSData dataWithBytes:blob + 8 length:blobLen - 8];
		id value = [NSPropertyListSerialization propertyListWithData:plist
			options:NSPropertyListImmutable format:NULL error:nil];
		return [value isKindOfClass:[NSDictionary class]] ? value : nil;
	}
	return nil;
}

// ---------- 容器化判定（对齐上游 constructContainerizationForEntitlements）----------

static BOOL containerizationFromEntitlements(NSDictionary *ents, NSString **customID)
{
	if (!ents) return YES;
	id noContainer = ents[@"com.apple.private.security.no-container"];
	if ([noContainer isKindOfClass:[NSNumber class]] && [(NSNumber *)noContainer boolValue]) return NO;
	id required = ents[@"com.apple.private.security.container-required"];
	if ([required isKindOfClass:[NSNumber class]] && ![(NSNumber *)required boolValue]) return NO;
	if ([required isKindOfClass:[NSString class]] && customID) *customID = (NSString *)required;
	return YES;
}

static NSDictionary *environmentForContainer(NSString *container, BOOL containerized)
{
	NSString *home = containerized ? container : @"/var/mobile";
	NSString *tmp = containerized ? [container stringByAppendingPathComponent:@"tmp"] : @"/var/tmp";
	return @{
		@"CFFIXED_USER_HOME": home,
		@"HOME": home,
		@"TMPDIR": tmp,
	};
}

static NSDictionary *groupContainersForEntitlements(NSDictionary *ents, BOOL systemGroups)
{
	if (!ents) return nil;
	NSString *key = systemGroups ? @"com.apple.security.system-groups" : @"com.apple.security.application-groups";
	NSString *clsName = systemGroups ? @"MCMSystemDataContainer" : @"MCMSharedDataContainer";
	NSArray *groups = ents[key];
	if (![groups isKindOfClass:[NSArray class]] || groups.count == 0) return nil;

	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	for (id group in (NSArray *)groups) {
		if (![group isKindOfClass:[NSString class]] || ![(NSString *)group length]) continue;
		id container = containerFor(clsName, @"MobileContainerManager", (NSString *)group, YES);
		NSString *path = containerPath(container);
		if (path.length) {
			out[(NSString *)group] = path;
		} else {
			logmsg(@"警告: group 容器创建失败 %@", group);
		}
	}
	return out.count ? out : nil;
}

static BOOL removeTree(NSString *path)
{
	if (!path.length) return YES;
	if (![FM() fileExistsAtPath:path]) return YES;
	NSError *error = nil;
	if (![FM() removeItemAtPath:path error:&error]) {
		logmsg(@"删除失败 %@: %@", path, error.localizedDescription);
		return NO;
	}
	return YES;
}

// ---------- patch-info ----------

static int cmd_patch_info(NSString *arg)
{
	NSString *path = resolveAppPath(arg);
	if (!path) {
		logmsg(@"找不到 app 目录: %@", arg);
		return TSREG_INFO;
	}
	NSURL *plistURL = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"Info.plist"]];
	NSDictionary *original = [NSDictionary dictionaryWithContentsOfURL:plistURL];
	if (![original isKindOfClass:[NSDictionary class]]) {
		logmsg(@"读不到 Info.plist: %@", plistURL.path);
		return TSREG_PATCH_FAILED;
	}
	NSMutableDictionary *info = [original mutableCopy];

	info[@"SBAppUsesLocalNotifications"] = @1;

	NSArray *urlTypes = info[@"CFBundleURLTypes"];
	if ([urlTypes isKindOfClass:[NSArray class]]) {
		NSSet *appleSchemes = systemURLSchemes(managedBundleIds());
		if (appleSchemes.count == 0) {
			logmsg(@"警告: 未枚举到系统应用 URL scheme，保留原有 scheme");
		} else {
			NSMutableArray *patched = [NSMutableArray array];
			for (id type in (NSArray *)urlTypes) {
				if (![type isKindOfClass:[NSDictionary class]]) continue;
				NSMutableDictionary *entry = [(NSDictionary *)type mutableCopy];
				NSArray *schemes = entry[@"CFBundleURLSchemes"];
				if ([schemes isKindOfClass:[NSArray class]]) {
					NSMutableArray *kept = [NSMutableArray array];
					for (id scheme in (NSArray *)schemes) {
						if (![scheme isKindOfClass:[NSString class]]) continue;
						if ([appleSchemes containsObject:[(NSString *)scheme lowercaseString]]) continue;
						[kept addObject:scheme];
					}
					entry[@"CFBundleURLSchemes"] = kept;
				}
				[patched addObject:entry];
			}
			info[@"CFBundleURLTypes"] = patched;
		}
	}

	NSError *error = nil;
	NSData *xml = [NSPropertyListSerialization dataWithPropertyList:info
		format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
	if (!xml || ![xml writeToURL:plistURL options:NSDataWritingAtomic error:&error]) {
		logmsg(@"写入 Info.plist 失败: %@", error.localizedDescription);
		return TSREG_PATCH_FAILED;
	}
	printf("PATCH path=%s\n", path.UTF8String);
	return TSREG_OK;
}

// ---------- register ----------

static int cmd_register(NSString *arg, BOOL forceUser)
{
	NSString *path = resolveAppPath(arg);
	if (!path) {
		logmsg(@"找不到 app 目录: %@", arg);
		return TSREG_INFO;
	}
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
	if (![info isKindOfClass:[NSDictionary class]]) {
		logmsg(@"读不到 Info.plist: %@/Info.plist", path);
		return TSREG_INFO;
	}
	NSString *bid = info[@"CFBundleIdentifier"];
	NSString *exe = info[@"CFBundleExecutable"];
	if (![bid isKindOfClass:[NSString class]] || !bid.length ||
	    ![exe isKindOfClass:[NSString class]] || !exe.length) {
		logmsg(@"Info.plist 缺少 CFBundleIdentifier / CFBundleExecutable");
		return TSREG_INFO;
	}
	NSString *exePath = [path stringByAppendingPathComponent:exe];
	if (![FM() fileExistsAtPath:exePath]) {
		logmsg(@"主可执行不存在: %@", exePath);
		return TSREG_INFO;
	}

	// 系统应用保护：只用密封卷路径 / installed.tsv 判定，RootHide 的 /Applications 自装应用不受影响
	NSSet *managed = managedBundleIds();
	if (![managed containsObject:bid.lowercaseString]) {
		if (isSystemBundlePath(path) || [systemBundleIds(managed) containsObject:bid.lowercaseString]) {
			logmsg(@"拒绝: %@ 是系统应用，不能注册", bid);
			return TSREG_IMMUTABLE;
		}
	}

	NSDictionary *ents = entitlementsFromMachO(exePath);
	NSString *customID = nil;
	BOOL containerized = containerizationFromEntitlements(ents, &customID);
	NSString *containerID = customID.length ? customID : bid;

	id dataContainer = containerFor(@"MCMAppDataContainer", @"MobileContainerManager", containerID, YES);
	NSString *dataPath = containerPath(dataContainer);
	if (!dataPath.length) {
		logmsg(@"警告: 数据容器创建失败（%@），注册继续但不带 Container", containerID);
	}

	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	if (ents) dict[@"Entitlements"] = ents;
	dict[@"ApplicationType"] = forceUser ? @"User" : @"System";
	dict[@"CFBundleIdentifier"] = bid;
	dict[@"CodeInfoIdentifier"] = bid;
	dict[@"CompatibilityState"] = @0;
	dict[@"IsContainerized"] = @(containerized);
	if (dataPath.length) {
		dict[@"Container"] = dataPath;
		dict[@"EnvironmentVariables"] = environmentForContainer(dataPath, containerized);
	}
	dict[@"IsDeletable"] = @(!([bid caseInsensitiveCompare:@"com.opa334.trollstore"] == NSOrderedSame ||
	                           [bid caseInsensitiveCompare:@"com.trollstorelite.tv"] == NSOrderedSame));
	dict[@"Path"] = [path stringByResolvingSymlinksInPath];
	dict[@"SignerOrganization"] = @"Apple Inc.";
	dict[@"SignatureVersion"] = @132352;
	dict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
	dict[@"IsAdHocSigned"] = @YES;
	dict[@"LSInstallType"] = @1;
	dict[@"HasMIDBasedSINF"] = @0;
	dict[@"MissingSINF"] = @0;
	dict[@"FamilyID"] = @0;
	dict[@"IsOnDemandInstallCapable"] = @0;

	NSString *team = ents[@"com.apple.developer.team-identifier"];
	if ([team isKindOfClass:[NSString class]]) dict[@"TeamIdentifier"] = team;

	// App Group / System Group 容器
	NSDictionary *appGroups = groupContainersForEntitlements(ents, NO);
	NSDictionary *systemGroups = groupContainersForEntitlements(ents, YES);
	NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
	if (appGroups.count) [groupContainers addEntriesFromDictionary:appGroups];
	if (systemGroups.count) [groupContainers addEntriesFromDictionary:systemGroups];
	if (appGroups.count) dict[@"HasAppGroupContainers"] = @YES;
	if (systemGroups.count) dict[@"HasSystemGroupContainers"] = @YES;
	if (groupContainers.count) dict[@"GroupContainers"] = groupContainers;

	// PlugIns/*.appex
	NSMutableDictionary *bundlePlugins = [NSMutableDictionary dictionary];
	NSString *pluginsPath = [path stringByAppendingPathComponent:@"PlugIns"];
	for (NSString *name in [FM() contentsOfDirectoryAtPath:pluginsPath error:nil]) {
		NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:name];
		NSDictionary *pluginInfo = [NSDictionary dictionaryWithContentsOfFile:
			[pluginPath stringByAppendingPathComponent:@"Info.plist"]];
		NSString *pluginBID = pluginInfo[@"CFBundleIdentifier"];
		NSString *pluginExe = pluginInfo[@"CFBundleExecutable"];
		if (![pluginBID isKindOfClass:[NSString class]] || !pluginBID.length ||
		    ![pluginExe isKindOfClass:[NSString class]] || !pluginExe.length) continue;
		NSString *pluginExePath = [pluginPath stringByAppendingPathComponent:pluginExe];
		NSDictionary *pluginEnts = entitlementsFromMachO(pluginExePath);
		NSString *pluginCustom = nil;
		BOOL pluginContainerized = containerizationFromEntitlements(pluginEnts, &pluginCustom);
		NSString *pluginContainerID = pluginCustom.length ? pluginCustom : pluginBID;
		id pluginContainer = containerFor(@"MCMPluginKitPluginDataContainer", @"MobileContainerManager",
			pluginContainerID, YES);
		NSString *pluginContainerPath = containerPath(pluginContainer);

		NSMutableDictionary *pluginDict = [NSMutableDictionary dictionary];
		if (pluginEnts) pluginDict[@"Entitlements"] = pluginEnts;
		pluginDict[@"ApplicationType"] = @"PluginKitPlugin";
		pluginDict[@"CFBundleIdentifier"] = pluginBID;
		pluginDict[@"CodeInfoIdentifier"] = pluginBID;
		pluginDict[@"CompatibilityState"] = @0;
		pluginDict[@"IsContainerized"] = @(pluginContainerized);
		if (pluginContainerPath.length) {
			pluginDict[@"Container"] = pluginContainerPath;
			pluginDict[@"EnvironmentVariables"] = environmentForContainer(pluginContainerPath, pluginContainerized);
		}
		pluginDict[@"Path"] = pluginPath;
		pluginDict[@"PluginOwnerBundleID"] = bid;
		pluginDict[@"SignerOrganization"] = @"Apple Inc.";
		pluginDict[@"SignatureVersion"] = @132352;
		pluginDict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
		NSString *pluginTeam = pluginEnts[@"com.apple.developer.team-identifier"];
		if ([pluginTeam isKindOfClass:[NSString class]]) pluginDict[@"TeamIdentifier"] = pluginTeam;

		NSDictionary *pluginAppGroups = groupContainersForEntitlements(pluginEnts, NO);
		NSDictionary *pluginSystemGroups = groupContainersForEntitlements(pluginEnts, YES);
		NSMutableDictionary *pluginGroups = [NSMutableDictionary dictionary];
		if (pluginAppGroups.count) [pluginGroups addEntriesFromDictionary:pluginAppGroups];
		if (pluginSystemGroups.count) [pluginGroups addEntriesFromDictionary:pluginSystemGroups];
		if (pluginAppGroups.count) pluginDict[@"HasAppGroupContainers"] = @YES;
		if (pluginSystemGroups.count) pluginDict[@"HasSystemGroupContainers"] = @YES;
		if (pluginGroups.count) pluginDict[@"GroupContainers"] = pluginGroups;

		bundlePlugins[pluginBID] = pluginDict;
	}
	dict[@"_LSBundlePlugins"] = bundlePlugins;

	id workspace = lsWorkspace();
	SEL registerSel = NSSelectorFromString(@"registerApplicationDictionary:");
	if (!workspace || ![workspace respondsToSelector:registerSel]) {
		logmsg(@"LSApplicationWorkspace registerApplicationDictionary: 不可用");
		return TSREG_REGISTER_FAILED;
	}
	BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, registerSel, dict);
	printf("REGISTER bid=%s ok=%d type=%s path=%s container=%s plugins=%lu\n",
		bid.UTF8String, ok ? 1 : 0, forceUser ? "User" : "System",
		path.UTF8String, dataPath.length ? dataPath.UTF8String : "(null)",
		(unsigned long)bundlePlugins.count);
	return ok ? TSREG_OK : TSREG_REGISTER_FAILED;
}

// ---------- unregister ----------

static int cmd_unregister(NSString *arg)
{
	NSString *path = nil;
	NSString *bid = nil;
	NSDictionary *info = nil;

	if ([arg hasPrefix:@"/"]) {
		path = resolveAppPath(arg) ?: arg;
		info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
		bid = info[@"CFBundleIdentifier"];
	} else {
		bid = arg;
	}

	id proxy = lsProxy(bid);
	if (!path.length && proxy) path = proxyBundlePath(proxy);
	if (!bid.length && path.length) {
		info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
		bid = info[@"CFBundleIdentifier"];
	}
	if (![bid isKindOfClass:[NSString class]] || !bid.length) {
		logmsg(@"找不到 bundle id（参数 %@）", arg);
		return TSREG_INFO;
	}
	if (!info && path.length) {
		info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
	}

	// 数据容器 id：entitlements 里的自定义容器名优先，其次 bundle id
	NSString *exe = info[@"CFBundleExecutable"];
	NSDictionary *ents = nil;
	if ([exe isKindOfClass:[NSString class]] && exe.length && path.length) {
		ents = entitlementsFromMachO([path stringByAppendingPathComponent:exe]);
	}
	NSString *customID = nil;
	containerizationFromEntitlements(ents, &customID);
	NSMutableSet *containerIDs = [NSMutableSet setWithObject:bid];
	if (customID.length) [containerIDs addObject:customID];

	NSURL *proxyData = proxyValue(proxy, @"dataContainerURL");
	if ([proxyData isKindOfClass:[NSURL class]]) removeTree(proxyData.path);
	for (NSString *containerID in containerIDs) {
		id container = containerFor(@"MCMAppDataContainer", @"MobileContainerManager", containerID, NO);
		removeTree(containerPath(container));
	}

	// App Group 容器：还有别的应用引用就保留
	NSDictionary *groups = proxyValue(proxy, @"groupContainerURLs");
	if ([groups isKindOfClass:[NSDictionary class]] && groups.count) {
		NSArray *all = lsAllProxies();
		for (NSString *groupID in groups) {
			BOOL shared = NO;
			for (id other in all) {
				NSString *otherBID = proxyValue(other, @"bundleIdentifier");
				if ([otherBID isKindOfClass:[NSString class]] && [otherBID isEqualToString:bid]) continue;
				NSDictionary *otherGroups = proxyValue(other, @"groupContainerURLs");
				if ([otherGroups isKindOfClass:[NSDictionary class]] && otherGroups[groupID]) {
					shared = YES;
					break;
				}
			}
			if (shared) {
				logmsg(@"保留共享 App Group: %@", groupID);
				continue;
			}
			removeTree(groups[groupID]);
		}
	}

	// 插件数据容器
	NSArray *plugins = proxyValue(proxy, @"plugInKitPlugins");
	if ([plugins isKindOfClass:[NSArray class]]) {
		for (id plugin in (NSArray *)plugins) {
			NSURL *pluginData = proxyValue(plugin, @"dataContainerURL");
			if ([pluginData isKindOfClass:[NSURL class]]) removeTree(pluginData.path);
		}
	}

	if (!proxy) {
		// 已经不在 LS 注册表里：容器清理完成即视为成功，避免卸载死锁
		printf("UNREGISTER bid=%s ok=0 reason=not-registered\n", bid.UTF8String);
		return TSREG_OK;
	}

	BOOL ok = NO;
	if (path.length) {
		id workspace = lsWorkspace();
		SEL unregisterSel = NSSelectorFromString(@"unregisterApplication:");
		if (workspace && [workspace respondsToSelector:unregisterSel]) {
			ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, unregisterSel,
				[NSURL fileURLWithPath:path]);
		}
	}
	printf("UNREGISTER bid=%s ok=%d path=%s\n", bid.UTF8String, ok ? 1 : 0,
		path.length ? path.UTF8String : "(null)");
	return ok ? TSREG_OK : TSREG_UNREGISTER_FAILED;
}

// ---------- query ----------

static int cmd_query(NSString *bid)
{
	id proxy = lsProxy(bid);
	if (!proxy) {
		printf("bid=%s\ninstalled=0\n", bid.UTF8String);
		return 1;
	}
	BOOL lsInstalled = msgBool(proxy, @"installed", NO);
	NSString *path = proxyBundlePath(proxy);
	if (!path.length) {
		// LS 会保留已注销 bundle 的空壳 proxy（path=nil），视为未安装
		printf("bid=%s\ninstalled=0\nls_installed=%d\n", bid.UTF8String, lsInstalled ? 1 : 0);
		return 1;
	}
	NSString *type = proxyValue(proxy, @"applicationType");
	if (![type isKindOfClass:[NSString class]]) type = @"(unknown)";
	NSURL *dataURL = proxyValue(proxy, @"dataContainerURL");
	if (![dataURL isKindOfClass:[NSURL class]]) dataURL = nil;
	// LS 可能不回报 Data Container；直接查 MCM（不创建）
	if (!dataURL) {
		id container = containerFor(@"MCMAppDataContainer", @"MobileContainerManager", bid, NO);
		NSString *cp = containerPath(container);
		if (cp.length) dataURL = [NSURL fileURLWithPath:cp];
	}
	BOOL containerized = msgBool(proxy, @"isContainerized", dataURL != nil);

	printf("bid=%s\n", bid.UTF8String);
	printf("installed=1\n");
	printf("ls_installed=%d\n", lsInstalled ? 1 : 0);
	printf("type=%s\n", type.UTF8String);
	printf("path=%s\n", path.length ? path.UTF8String : "(null)");
	printf("containerized=%d\n", containerized ? 1 : 0);
	printf("data_container=%s\n", dataURL ? dataURL.path.UTF8String : "(null)");
	return 0;
}

// ---------- classify（只读诊断：不发任何注册/容器请求）----------

static int cmd_classify(NSString *arg)
{
	NSString *resolved = resolveAppPath(arg);
	NSString *target = resolved ?: arg;
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
		[target stringByAppendingPathComponent:@"Info.plist"]];
	NSString *bid = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
		? info[@"CFBundleIdentifier"] : @"(unknown)";
	NSSet *managed = managedBundleIds();
	BOOL managedHit = [bid isKindOfClass:[NSString class]] && [managed containsObject:bid.lowercaseString];
	BOOL system = isSystemBundlePath(target);
	BOOL systemByBid = [bid isKindOfClass:[NSString class]] &&
		[systemBundleIds(managed) containsObject:bid.lowercaseString];
	printf("arg=%s\nresolved=%s\nbid=%s\nsystem_path=%d\nsystem_bid=%d\nmanaged=%d\n",
		arg.UTF8String, target.UTF8String, bid.UTF8String,
		system ? 1 : 0, systemByBid ? 1 : 0, managedHit ? 1 : 0);
	return 0;
}

static void usage(void)
{
	logmsg(@"用法: tsreg patch-info <app> | register <app> [--user] | unregister <app|bid> | query <bid> | classify <path>");
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (geteuid() != 0) {
			logmsg(@"必须以 root 运行");
			return 1;
		}
		if (argc < 3) {
			usage();
			return TSREG_USAGE;
		}
		NSString *cmd = [NSString stringWithUTF8String:argv[1]];
		NSString *arg = [NSString stringWithUTF8String:argv[2]];
		BOOL forceUser = NO;
		for (int i = 3; i < argc; i++) {
			if (strcmp(argv[i], "--user") == 0) forceUser = YES;
		}

		if ([cmd isEqualToString:@"patch-info"]) return cmd_patch_info(arg);
		if ([cmd isEqualToString:@"register"]) return cmd_register(arg, forceUser);
		if ([cmd isEqualToString:@"unregister"]) return cmd_unregister(arg);
		if ([cmd isEqualToString:@"query"]) return cmd_query(arg);
		if ([cmd isEqualToString:@"classify"]) return cmd_classify(arg);

		usage();
		return TSREG_USAGE;
	}
}
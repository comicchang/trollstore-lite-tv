// entfix —— 按上游 TrollStore RootHelper 的规则修正 entitlements（Lite 路径）
//
// 对照实现（opa334/TrollStore RootHelper/main.m · signApp）：
//   1. 每个 bundle 的主可执行沿用其原有 entitlements；主 app 若一个都没有，
//      回落 Xcode 风格最小集合（application-identifier=TROLLTROLL.* 等）。
//   2. container-required 归一：
//        - 缺省视为需要容器；
//        - 布尔 false → 不处理；
//        - 字符串（自定义容器 id）→ 原样保留；
//        - 需要容器且没有 no-container/no-sandbox → 写成字符串 <bundle-id>。
//   3. TrollStore Lite 额外写 jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE，
//      让 PMAP_CS 设备以 App Store 信任级运行 ad-hoc 签名（Dopamine 2.1.5+）。
//
// 用法: entfix [--fallback] [--lite-pmap] <bundle-id>   < in.plist > out.plist
// 输入/输出全部走 stdin/stdout（零文件路径系统调用）：tvOS 上 ad-hoc + 信任缓存的
// 二进制读写绝对路径会被 RootHide/vroot 命名空间拒绝（open 返回 ENOENT），
// 而 shell 重定向走的是受信 shell 的命名空间。
// 退出码: 0 成功 / 1 entitlements 根节点不是 dict / 2 用法错误 / 3 序列化或写出失败

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static BOOL dictBool(NSDictionary *dict, NSString *key, BOOL defaultValue)
{
	NSObject *value = dict[key];
	if (value && [value isKindOfClass:[NSNumber class]]) {
		return [(NSNumber *)value boolValue];
	}
	return defaultValue;
}

static void usage(const char *argv0)
{
	fprintf(stderr, "用法: %s [--fallback] [--lite-pmap] <bundle-id> < in.plist > out.plist\n", argv0);
}

int main(int argc, char *argv[])
{
	@autoreleasepool {
		BOOL fallback = NO;
		BOOL litePmap = NO;
		NSMutableArray<NSString *> *positional = [NSMutableArray array];

		for (int i = 1; i < argc; i++) {
			NSString *arg = [NSString stringWithUTF8String:argv[i]];
			if ([arg isEqualToString:@"--fallback"]) {
				fallback = YES;
			} else if ([arg isEqualToString:@"--lite-pmap"]) {
				litePmap = YES;
			} else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
				usage(argv[0]);
				return 0;
			} else {
				[positional addObject:arg];
			}
		}

		if (positional.count != 1) {
			usage(argv[0]);
			return 2;
		}

		NSString *bundleID = positional[0];

		// 读不出/损坏的 entitlements 按空处理（与上游 dumpEntitlements 失败返回 nil 一致）；
		// 但若解析成功且根节点不是 dict，则与上游一样报错。
		NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
		id parsed = nil;
		if (input.length > 0) {
			parsed = [NSPropertyListSerialization propertyListWithData:input
			                                                   options:NSPropertyListImmutable
			                                                    format:NULL
			                                                     error:NULL];
			if (parsed && ![parsed isKindOfClass:[NSDictionary class]]) {
				fprintf(stderr, "entfix: entitlements 根节点不是 dict\n");
				return 1;
			}
		}

		NSMutableDictionary *entitlements = [parsed isKindOfClass:[NSDictionary class]]
			? [(NSDictionary *)parsed mutableCopy]
			: [NSMutableDictionary dictionary];

		if (fallback && entitlements.count == 0) {
			entitlements[@"application-identifier"] = @"TROLLTROLL.*";
			entitlements[@"com.apple.developer.team-identifier"] = @"TROLLTROLL";
			entitlements[@"get-task-allow"] = @YES;
			entitlements[@"keychain-access-groups"] = @[ @"TROLLTROLL.*", @"com.apple.token" ];
		}

		NSObject *containerRequiredValue = entitlements[@"com.apple.private.security.container-required"];
		BOOL containerRequired = YES;
		if ([containerRequiredValue isKindOfClass:[NSNumber class]]) {
			containerRequired = [(NSNumber *)containerRequiredValue boolValue];
		} else if ([containerRequiredValue isKindOfClass:[NSString class]]) {
			containerRequired = NO; // 自定义容器 id：原样保留
		}

		if (containerRequired) {
			BOOL noContainer = dictBool(entitlements, @"com.apple.private.security.no-container", NO);
			BOOL noSandbox = dictBool(entitlements, @"com.apple.private.security.no-sandbox", NO);
			if (!noContainer && !noSandbox) {
				entitlements[@"com.apple.private.security.container-required"] = bundleID;
			}
		}

		if (litePmap) {
			entitlements[@"jb.pmap_cs.custom_trust"] = @"PMAP_CS_APP_STORE";
		}

		NSError *serializationError = nil;
		NSData *xml = [NSPropertyListSerialization dataWithPropertyList:entitlements
		                                                         format:NSPropertyListXMLFormat_v1_0
		                                                        options:0
		                                                          error:&serializationError];
		if (!xml) {
			fprintf(stderr, "entfix: 序列化失败: %s\n", serializationError.localizedDescription.UTF8String);
			return 3;
		}
		if (fwrite(xml.bytes, 1, xml.length, stdout) != xml.length) {
			fprintf(stderr, "entfix: 写出失败 (%s)\n", strerror(errno));
			return 3;
		}
		return 0;
	}
}

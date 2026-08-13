#import "FFFileTask.h"

@implementation FFFileTask

- (instancetype)init
{
    self = [super init];
    if (self) {
        _taskID = [NSUUID UUID].UUIDString;
        _state = FFFileTaskStateQueued;
    }
    return self;
}

- (NSString *)stateText
{
    switch (self.state) {
        case FFFileTaskStateQueued: return @"排队中";
        case FFFileTaskStateRunning: return @"进行中";
        case FFFileTaskStateCompleted: return @"已完成";
        case FFFileTaskStateFailed: return @"失败";
        case FFFileTaskStateCancelled: return @"已取消";
    }
    return @"";
}

- (NSString *)kindText
{
    switch (self.kind) {
        case FFFileTaskKindCopy: return @"复制";
        case FFFileTaskKindMove: return @"移动";
        case FFFileTaskKindExtract: return @"解压";
        case FFFileTaskKindCompress: return @"压缩";
    }
    return @"";
}

@end

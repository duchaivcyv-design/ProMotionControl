#import "PMLocalBridge.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/time.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdint.h>

#define PM_SOCKET_PATH "/var/tmp/com.dell.promotioncontrol.socket"
#define PM_BRIDGE_TIMEOUT_MS 450
#define PM_BRIDGE_RESPONSE_MAX 512

static dispatch_queue_t PMBridgeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.dell.promotioncontrol.admin-bridge", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL PMBridgeCommandIsAllowed(NSString *command) {
    if (![command isKindOfClass:[NSString class]]) return NO;
    static NSSet<NSString *> *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[@"status", @"thermal_reduce", @"thermal_resume"]];
    });
    return [allowed containsObject:command];
}

static BOOL PMBridgeWait(int fd, short events) {
    struct pollfd descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    descriptor.fd = fd;
    descriptor.events = events;
    int result;
    do {
        result = poll(&descriptor, 1, PM_BRIDGE_TIMEOUT_MS);
    } while (result < 0 && errno == EINTR);
    // A peer may send its final response and close immediately; POLLIN|POLLHUP
    // still means buffered response bytes can be read.
    return result > 0 && (descriptor.revents & events) != 0 &&
        (descriptor.revents & (POLLERR | POLLNVAL)) == 0;
}

static BOOL PMPerformBridgeCommand(NSString *command, NSString **responseOutput) {
    if (responseOutput) *responseOutput = nil;
    if (!PMBridgeCommandIsAllowed(command)) {
        if (responseOutput) *responseOutput = @"Lệnh không nằm trong danh sách ADMIN được phép.";
        return NO;
    }
    if ([NSThread isMainThread]) {
        if (responseOutput) *responseOutput = @"Socket ADMIN chỉ được gọi ngoài luồng giao diện.";
        return NO;
    }

    // Fail closed: do not follow a substituted filesystem entry and only talk
    // to a root-owned Unix socket. The peer credentials are checked again below.
    struct stat socketInfo;
    if (lstat(PM_SOCKET_PATH, &socketInfo) != 0 || !S_ISSOCK(socketInfo.st_mode) ||
        socketInfo.st_uid != 0 || (socketInfo.st_mode & S_IWOTH) != 0) {
        if (responseOutput) *responseOutput = @"Daemon ADMIN chưa sẵn sàng hoặc socket không an toàn.";
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (responseOutput) *responseOutput = @"Không thể tạo socket cục bộ.";
        return NO;
    }
    int closeOnExec = fcntl(fd, F_GETFD, 0);
    if (closeOnExec >= 0) (void)fcntl(fd, F_SETFD, closeOnExec | FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

    int originalFlags = fcntl(fd, F_GETFL, 0);
    if (originalFlags < 0 || fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != 0) {
        close(fd);
        if (responseOutput) *responseOutput = @"Không thể cấu hình socket không chặn.";
        return NO;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, PM_SOCKET_PATH, sizeof(address.sun_path));
    int connected = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (connected != 0 && errno != EINPROGRESS) {
        close(fd);
        if (responseOutput) *responseOutput = @"Không thể kết nối daemon ADMIN.";
        return NO;
    }
    if (connected != 0) {
        if (!PMBridgeWait(fd, POLLOUT)) {
            close(fd);
            if (responseOutput) *responseOutput = @"Hết thời gian kết nối daemon ADMIN.";
            return NO;
        }
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 || socketError != 0) {
            close(fd);
            if (responseOutput) *responseOutput = @"Daemon ADMIN từ chối kết nối.";
            return NO;
        }
    }

#if defined(__APPLE__)
    uid_t peerUID = (uid_t)-1;
    gid_t peerGID = (gid_t)-1;
    if (getpeereid(fd, &peerUID, &peerGID) != 0 || peerUID != 0) {
        close(fd);
        if (responseOutput) *responseOutput = @"Từ chối daemon không chạy bằng UID root.";
        return NO;
    }
#endif

    // Restore blocking state only with bounded send/receive timeouts.
    (void)fcntl(fd, F_SETFL, originalFlags);
    struct timeval timeout;
    timeout.tv_sec = 0;
    timeout.tv_usec = PM_BRIDGE_TIMEOUT_MS * 1000;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    NSString *wireCommand = [command stringByAppendingString:@"\n"];
    NSData *payload = [wireCommand dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = payload.bytes;
    size_t totalSent = 0;
    while (totalSent < payload.length) {
        ssize_t count = send(fd, bytes + totalSent, payload.length - totalSent, 0);
        if (count > 0) {
            totalSent += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        close(fd);
        if (responseOutput) *responseOutput = @"Không gửi đủ lệnh tới daemon ADMIN.";
        return NO;
    }

    char buffer[PM_BRIDGE_RESPONSE_MAX + 1];
    memset(buffer, 0, sizeof(buffer));
    size_t used = 0;
    BOOL receivedLine = NO;
    while (used < PM_BRIDGE_RESPONSE_MAX) {
        ssize_t count = recv(fd, buffer + used, PM_BRIDGE_RESPONSE_MAX - used, 0);
        if (count > 0) {
            size_t oldUsed = used;
            used += (size_t)count;
            if (memchr(buffer + oldUsed, '\n', (size_t)count) != NULL) {
                receivedLine = YES;
                break;
            }
            continue;
        }
        if (count == 0) break;
        if (errno == EINTR) continue;
        break;
    }
    close(fd);

    if (used == 0 || (!receivedLine && used == PM_BRIDGE_RESPONSE_MAX)) {
        if (responseOutput) *responseOutput = @"Không nhận được phản hồi hợp lệ từ daemon ADMIN.";
        return NO;
    }
    size_t responseLength = used;
    char *newline = memchr(buffer, '\n', used);
    if (newline) responseLength = (size_t)(newline - buffer);
    NSString *response = [[NSString alloc] initWithBytes:buffer length:responseLength encoding:NSUTF8StringEncoding];
    if (![response isKindOfClass:[NSString class]] || response.length == 0) {
        if (responseOutput) *responseOutput = @"Phản hồi daemon ADMIN không phải UTF-8 hợp lệ.";
        return NO;
    }
    if (responseOutput) *responseOutput = response;
    return YES;
}

@implementation PMLocalBridge

+ (BOOL)sendLocalCommand:(NSString *)command responseOutput:(NSString **)responseOutput {
    return PMPerformBridgeCommand(command, responseOutput);
}

+ (void)sendLocalCommand:(NSString *)command completion:(void (^)(BOOL, NSString *))completion {
    NSString *commandCopy = [command copy] ?: @"";
    dispatch_async(PMBridgeQueue(), ^{
        NSString *response = nil;
        BOOL success = PMPerformBridgeCommand(commandCopy, &response);
        if (completion) {
            NSString *result = [response copy] ?: @"Không có phản hồi.";
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, result);
            });
        }
    });
}

@end

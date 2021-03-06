//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "TSStorageManager.h"
#import "OWSAnalytics.h"
#import "OWSBatchMessageProcessor.h"
#import "OWSDisappearingMessagesFinder.h"
#import "OWSFailedAttachmentDownloadsJob.h"
#import "OWSFailedMessagesJob.h"
#import "OWSFileSystem.h"
#import "OWSIncomingMessageFinder.h"
#import "OWSMessageReceiver.h"
#import "OWSStorage+Subclass.h"
#import "TSDatabaseSecondaryIndexes.h"
#import "TSDatabaseView.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const TSStorageManagerExceptionName_CouldNotMoveDatabaseFile
    = @"TSStorageManagerExceptionName_CouldNotMoveDatabaseFile";
NSString *const TSStorageManagerExceptionName_CouldNotCreateDatabaseDirectory
    = @"TSStorageManagerExceptionName_CouldNotCreateDatabaseDirectory";

#pragma mark -

@interface TSStorageManager ()

@property (nonatomic, readonly, nullable) YapDatabaseConnection *dbReadConnection;
@property (nonatomic, readonly, nullable) YapDatabaseConnection *dbReadWriteConnection;

@property (atomic) BOOL areAsyncRegistrationsComplete;
@property (atomic) BOOL areSyncRegistrationsComplete;

@end

#pragma mark -

@implementation TSStorageManager

+ (instancetype)sharedManager {
    static TSStorageManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] initStorage];

#if TARGET_OS_IPHONE
        [TSStorageManager protectFiles];
#endif
    });
    return sharedManager;
}

- (instancetype)initStorage
{
    self = [super initStorage];

    if (self) {
        _dbReadConnection = self.newDatabaseConnection;
        _dbReadWriteConnection = self.newDatabaseConnection;

        OWSSingletonAssert();
    }

    return self;
}

- (void)resetStorage
{
    _dbReadConnection = nil;
    _dbReadWriteConnection = nil;

    [super resetStorage];
}

- (void)runSyncRegistrations
{
    // Synchronously register extensions which are essential for views.
    [TSDatabaseView registerCrossProcessNotifier];
    [TSDatabaseView registerThreadInteractionsDatabaseView];
    [TSDatabaseView registerThreadDatabaseView];
    [TSDatabaseView registerUnreadDatabaseView];
    [self registerExtension:[TSDatabaseSecondaryIndexes registerTimeStampIndex] withName:@"idx"];
    [OWSMessageReceiver syncRegisterDatabaseExtension:self];
    [OWSBatchMessageProcessor syncRegisterDatabaseExtension:self];

    // See comments on OWSDatabaseConnection.
    //
    // In the absence of finding documentation that can shed light on the issue we've been
    // seeing, this issue only seems to affect sync and not async registrations.  We've always
    // been opening write transactions before the async registrations complete without negative
    // consequences.
    OWSAssert(!self.areSyncRegistrationsComplete);
    self.areSyncRegistrationsComplete = YES;
}

- (void)runAsyncRegistrationsWithCompletion:(void (^_Nonnull)(void))completion
{
    OWSAssert(completion);

    // Asynchronously register other extensions.
    //
    // All sync registrations must be done before all async registrations,
    // or the sync registrations will block on the async registrations.
    [TSDatabaseView asyncRegisterUnseenDatabaseView];
    [TSDatabaseView asyncRegisterThreadOutgoingMessagesDatabaseView];
    [TSDatabaseView asyncRegisterThreadSpecialMessagesDatabaseView];

    // Register extensions which aren't essential for rendering threads async.
    [OWSIncomingMessageFinder asyncRegisterExtensionWithStorageManager:self];
    [TSDatabaseView asyncRegisterSecondaryDevicesDatabaseView];
    [OWSDisappearingMessagesFinder asyncRegisterDatabaseExtensions:self];
    [OWSFailedMessagesJob asyncRegisterDatabaseExtensionsWithStorageManager:self];
    [OWSFailedAttachmentDownloadsJob asyncRegisterDatabaseExtensionsWithStorageManager:self];

    // Block until all async registrations are complete.
    [self.newDatabaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        OWSAssert(!self.areAsyncRegistrationsComplete);

        self.areAsyncRegistrationsComplete = YES;

        completion();
    }];
}

+ (void)protectFiles
{
    // The old database location was in the Document directory,
    // so protect the database files individually.
    [OWSFileSystem protectFolderAtPath:self.legacyDatabaseFilePath];
    [OWSFileSystem protectFolderAtPath:self.legacyDatabaseFilePath_SHM];
    [OWSFileSystem protectFolderAtPath:self.legacyDatabaseFilePath_WAL];

    // Protect the entire new database directory.
    [OWSFileSystem protectFolderAtPath:self.sharedDataDatabaseDirPath];
}

- (BOOL)userSetPassword {
    return FALSE;
}

+ (NSString *)legacyDatabaseDirPath
{
    return [OWSFileSystem appDocumentDirectoryPath];
}

+ (NSString *)sharedDataDatabaseDirPath
{
    NSString *databaseDirPath = [[OWSFileSystem appSharedDataDirectoryPath] stringByAppendingPathComponent:@"database"];

    if (![OWSFileSystem ensureDirectoryExists:databaseDirPath]) {
        [NSException raise:TSStorageManagerExceptionName_CouldNotCreateDatabaseDirectory
                    format:@"Could not create new database directory"];
    }
    return databaseDirPath;
}

+ (NSString *)databaseFilename
{
    return @"Signal.sqlite";
}

+ (NSString *)databaseFilename_SHM
{
    return [self.databaseFilename stringByAppendingString:@"-shm"];
}

+ (NSString *)databaseFilename_WAL
{
    return [self.databaseFilename stringByAppendingString:@"-wal"];
}

+ (NSString *)legacyDatabaseFilePath
{
    return [self.legacyDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename];
}

+ (NSString *)legacyDatabaseFilePath_SHM
{
    return [self.legacyDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename_SHM];
}

+ (NSString *)legacyDatabaseFilePath_WAL
{
    return [self.legacyDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename_WAL];
}

+ (NSString *)sharedDataDatabaseFilePath
{
    return [self.sharedDataDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename];
}

+ (NSString *)sharedDataDatabaseFilePath_SHM
{
    return [self.sharedDataDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename_SHM];
}

+ (NSString *)sharedDataDatabaseFilePath_WAL
{
    return [self.sharedDataDatabaseDirPath stringByAppendingPathComponent:self.databaseFilename_WAL];
}

+ (void)migrateToSharedData
{
    [OWSFileSystem moveAppFilePath:self.legacyDatabaseFilePath
                sharedDataFilePath:self.sharedDataDatabaseFilePath
                     exceptionName:TSStorageManagerExceptionName_CouldNotMoveDatabaseFile];
    [OWSFileSystem moveAppFilePath:self.legacyDatabaseFilePath_SHM
                sharedDataFilePath:self.sharedDataDatabaseFilePath_SHM
                     exceptionName:TSStorageManagerExceptionName_CouldNotMoveDatabaseFile];
    [OWSFileSystem moveAppFilePath:self.legacyDatabaseFilePath_WAL
                sharedDataFilePath:self.sharedDataDatabaseFilePath_WAL
                     exceptionName:TSStorageManagerExceptionName_CouldNotMoveDatabaseFile];
}

+ (NSString *)databaseFilePath
{
    DDLogVerbose(@"databasePath: %@", TSStorageManager.sharedDataDatabaseFilePath);

    return self.sharedDataDatabaseFilePath;
}

- (NSString *)databaseFilePath
{
    return TSStorageManager.databaseFilePath;
}

+ (YapDatabaseConnection *)dbReadConnection
{
    return TSStorageManager.sharedManager.dbReadConnection;
}

+ (YapDatabaseConnection *)dbReadWriteConnection
{
    return TSStorageManager.sharedManager.dbReadWriteConnection;
}

@end

NS_ASSUME_NONNULL_END

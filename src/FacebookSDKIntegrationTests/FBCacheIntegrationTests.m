/*
 * Copyright 2010-present Facebook.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBCacheDescriptor.h"
#import "FBCacheIndex.h"
#import "FBDataDiskCache.h"
#import "FBFriendPickerCacheDescriptor.h"
#import "FBFriendPickerViewController+Internal.h"
#import "FBFriendPickerViewController.h"
#import "FBIntegrationTests.h"
#import "FBRequest.h"
#import "FBRequestConnection+Internal.h"
#import "FBRequestConnection.h"
#import "FBTestBlocker.h"
#import "FBTestSession.h"

#if defined(FACEBOOKSDK_SKIP_CACHE_TESTS)

#pragma message ("warning: Skipping FBCacheIntegrationTests")

#else

@class FBCacheEntityInfo;

@interface FBCacheIndex (FBCacheIntegrationTests)
- (FBCacheEntityInfo *)_readEntryFromDatabase:(NSString *)key;
@end

@interface FBFriendPickerCacheDescriptor (FBCacheIntegrationTests)
@property (nonatomic, readwrite, assign) BOOL hasCompletedFetch;
- (FBRequest *)requestForLoadData;
@end

@interface FBCacheIntegrationTests : FBIntegrationTests<FBCacheIndexFileDelegate>
@property (retain, nonatomic) NSString *dataCachePath;
@end

static NSString *nameForTestCache()
{
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidString =
    (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);

    CFRelease(uuid);
    NSString *result = [NSString stringWithFormat:@"test_cache-%@",uuidString];

    [uuidString release];
    return result;
}

static FBCacheIndex *initTempCacheIndex(
                                        FBCacheIntegrationTests *testInstance,
                                        NSString **tempFolder)
{
    NSString *tmp = [NSTemporaryDirectory()
                     stringByAppendingPathComponent:nameForTestCache()];
    [[NSFileManager defaultManager]
     createDirectoryAtPath:tmp
     withIntermediateDirectories:YES
     attributes:nil
     error:nil];

    FBCacheIndex *cacheIndex = [[FBCacheIndex alloc] initWithCacheFolder:tmp];
    cacheIndex.delegate = testInstance;
    testInstance.dataCachePath = tmp;

    *tempFolder = tmp;
    return cacheIndex;
}

@implementation FBCacheIntegrationTests
{
    NSString *_dataCachePath;
    dispatch_queue_t _fileQueue;
}

#pragma mark - Setup/Teardown

- (void)setUp
{
    [super setUp];

    dispatch_queue_t bgPriQueue =
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    _fileQueue = dispatch_queue_create(
                                       "File Cache Queue",
                                       DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_fileQueue, bgPriQueue);

}

- (void)tearDown
{
    [super tearDown];
}

#pragma mark - FBCacheIndexFileDelegate

- (void)cacheIndex:(FBCacheIndex *)cacheIndex
 writeFileWithName:(NSString *)name
              data:(NSData *)data
{
    NSString *path =
    [_dataCachePath stringByAppendingPathComponent:name];

    dispatch_async(_fileQueue, ^{
        [data writeToFile:path atomically:YES];
    });
}

- (void)cacheIndex:(FBCacheIndex *)cacheIndex
deleteFileWithName:(NSString *)name
{
    NSString *filePath = [_dataCachePath stringByAppendingPathComponent:name];
    dispatch_async(_fileQueue, ^{
        [[NSFileManager defaultManager]
         removeItemAtPath:filePath
         error:nil];
    });
}

#pragma mark - Test methods

- (void)testStoreAndRetrieve
{
    FBDataDiskCache *cache = [FBDataDiskCache sharedCache];

    NSData *data = [@"Test Data" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:@"http://www.facebook.com/test/url1"];
    [cache setData:data forURL:url];

    NSData *readData = [cache dataForURL:url];
    XCTAssertTrue([readData isEqualToData:data], @"Data equality fail.");
}

- (void)testDeleteAndRetrieve
{
    FBDataDiskCache *cache = [FBDataDiskCache sharedCache];

    NSData *data = [@"Test Data" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:@"http://www.facebook.com/test/url2"];
    [cache setData:data forURL:url];
    [cache removeDataForUrl:url];

    NSData *readData = [cache dataForURL:url];
    XCTAssertNil(readData, @"Data should be removed.");
}

- (void)testCacheIndex
{
    NSString *tempFolder;
    FBCacheIndex *cacheIndex = initTempCacheIndex(self, &tempFolder);
    cacheIndex.diskCapacity = 100000; // prevent trimming for this simple test

    NSString *dummy = [@""
                       stringByPaddingToLength:100
                       withString:@"1"
                       startingAtIndex:0];

    NSData *dummyData = [dummy dataUsingEncoding:NSUTF8StringEncoding];
    NSString *fileName =
    [cacheIndex storeFileForKey:@"test1" withData:dummyData];
    NSString *filePath = [tempFolder stringByAppendingPathComponent:fileName];

    // Flush the write queue
    dispatch_sync(cacheIndex.databaseQueue, ^{});

    __block FBCacheEntityInfo *info = nil;
    dispatch_sync(cacheIndex.databaseQueue, ^{
        info = [cacheIndex performSelector:@selector(_readEntryFromDatabase:) withObject:@"test1"];
    });

    XCTAssertNotNil(info, @"Index not written to disk!");
    XCTAssertEqual(
                   cacheIndex.currentDiskUsage,
                   dummyData.length,
                   @"Cache disk usage incorrect");

    // Flush background databaseQueue
    dispatch_sync(_fileQueue, ^{});

    BOOL fileExists =
    [[NSFileManager defaultManager] fileExistsAtPath:filePath];
    XCTAssertTrue(fileExists, @"File not written to disk");

    // Delete the entry
    [cacheIndex removeEntryForKey:@"test1"];

    // Flush the write queue
    dispatch_sync(cacheIndex.databaseQueue, ^{});
    dispatch_sync(_fileQueue, ^{});

    fileExists = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
    XCTAssertFalse(fileExists, @"File not deleted on removal");

    NSString *entry = [cacheIndex fileNameForKey:@"test1"];
    XCTAssertNil(entry, @"Entry not removed");

    [cacheIndex release];
    [[NSFileManager defaultManager] removeItemAtPath:tempFolder error:NULL];
}

- (void)testCacheIndexFailsInitWithBadPath {
    FBCacheIndex *cacheIndex = [[FBCacheIndex alloc] initWithCacheFolder:@"/no/such/folder"];
    XCTAssertNil(cacheIndex, @"initWithCacheFolder should fail");
}

- (void)testDataPersistence
{
    const NSUInteger numberOfFiles = 100;
    const NSUInteger fileSize = 1000;

    NSString *tempFolder;
    FBCacheIndex *cacheIndex = initTempCacheIndex(self, &tempFolder);
    cacheIndex.diskCapacity = numberOfFiles * fileSize;

    NSString *dummy = [@""
                       stringByPaddingToLength:fileSize
                       withString:@"1" startingAtIndex:0];

    NSData *dummyData = [dummy
                         dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger counter = 0; counter < numberOfFiles; counter++) {
        NSString *fileName = [cacheIndex
                              storeFileForKey:[NSString stringWithFormat:@"test%lu", (unsigned long)counter]
                              withData:dummyData];
        XCTAssertNotNil(fileName, @"");
    }

    // Wait for the queue to finish
    dispatch_sync(cacheIndex.databaseQueue, ^{});
    XCTAssertEqual(
                   cacheIndex.currentDiskUsage,
                   fileSize * numberOfFiles,
                   @"Disk usage computed incorrectly");

    // Now recreate the queue and ensure the disk size is still right
    [cacheIndex release];
    cacheIndex = [[FBCacheIndex alloc] initWithCacheFolder:tempFolder];
    cacheIndex.delegate = self;

    // Wait for the queue to finish
    dispatch_sync(cacheIndex.databaseQueue, ^{});
    dispatch_sync(_fileQueue, ^{});
    XCTAssertEqual(
                   cacheIndex.currentDiskUsage,
                   fileSize * numberOfFiles,
                   @"Disk usage computed incorrectly");

    // test that the data is still there
    for (int counter = 0; counter < numberOfFiles; counter++) {
        NSString *key = [NSString stringWithFormat:@"test%lu", (unsigned long)counter];
        NSString *fileName = [cacheIndex fileNameForKey:key];
        XCTAssertNotNil(fileName, @"Entity missing from the cache");

        NSError *error;
        NSData *readData = [NSData
                            dataWithContentsOfFile:[tempFolder
                                                    stringByAppendingPathComponent:fileName]
                            options:NSDataReadingMappedAlways | NSDataReadingUncached
                            error:&error];
        XCTAssertNotNil(readData, @"Data file not found");
        XCTAssertEqual(readData.length, fileSize, @"Data length incorrect");
    }

    [cacheIndex release];
    [[NSFileManager defaultManager] removeItemAtPath:tempFolder error:NULL];
}

- (void)testTrimming
{
    const NSUInteger numberOfFiles = 100;
    const NSUInteger fileSize = 1000;

    NSString *tempFolder;
    FBCacheIndex *cacheIndex = initTempCacheIndex(self, &tempFolder);
    cacheIndex.diskCapacity = fileSize * numberOfFiles / 2;

    NSString *dummy = [@""
                       stringByPaddingToLength:fileSize
                       withString:@"1"
                       startingAtIndex:0];
    NSData *dummyData = [dummy dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger counter = 0; counter < numberOfFiles; counter++) {
        NSString *fileName = [cacheIndex
                              storeFileForKey:[NSString stringWithFormat:@"test%lu", (unsigned long)counter]
                              withData:dummyData];
        XCTAssertNotNil(fileName, @"");
    }

    // Wait for the queue to flush
    dispatch_sync(cacheIndex.databaseQueue, ^{});

    // We stored twice as much as the cache would support - let's ensure
    // the first 50% of the files are gone
    for (int i = 0; i < numberOfFiles * 0.5; i++) {
        NSString *key = [NSString stringWithFormat:@"test%d", i];
        NSString *fileName = [cacheIndex fileNameForKey:key];
        XCTAssertNil(
                    fileName,
                    @"Expected info at index %d to be scavenged, still present",
                    i);
    }

    // There's no exact number to look for here, but at least the newest 40%
    // of the files should be there.
    for (int i = numberOfFiles - 1; i > numberOfFiles * 0.6; i--) {
        NSString *key = [NSString stringWithFormat:@"test%d", i];
        NSString *fileName = [cacheIndex fileNameForKey:key];
        XCTAssertNotNil(
                       fileName,
                       @"Expected info at index %d to be present, was scavenged",
                       i);
    }

    XCTAssertTrue(
                 cacheIndex.currentDiskUsage < numberOfFiles * fileSize / 2,
                 @"Current disk usage incorrect");
    [cacheIndex release];
    [[NSFileManager defaultManager] removeItemAtPath:tempFolder error:NULL];
}

- (void)testDeletingUsedData
{
    NSString *tempFolder;
    FBCacheIndex *cacheIndex = initTempCacheIndex(self, &tempFolder);
    cacheIndex.diskCapacity = 100000; // no trimming for this simple test

    NSString *dummy = [@""
                       stringByPaddingToLength:100
                       withString:@"1"
                       startingAtIndex:0];
    NSData *dummyData = [dummy dataUsingEncoding:NSUTF8StringEncoding];

    NSString *fileName = [cacheIndex
                          storeFileForKey:@"test1"
                          withData:dummyData];
    NSString *filePath = [tempFolder
                          stringByAppendingPathComponent:fileName];

    // Flush the write queues
    dispatch_sync(cacheIndex.databaseQueue, ^{});
    dispatch_sync(_fileQueue, ^{});

    NSData *dataFromFile = [NSData
                            dataWithContentsOfFile:filePath
                            options:NSDataReadingMappedAlways | NSDataReadingUncached
                            error:nil];
    XCTAssertEqual(
                   dataFromFile.length,
                   dummyData.length,
                   @"Read something different from what we wrote");

    NSString *stringFromFile = [[NSString alloc]
                                initWithData:dataFromFile
                                encoding:NSUTF8StringEncoding];
    XCTAssertTrue(
                 [stringFromFile isEqualToString:dummy],
                 @"Payload doesn't match!");

    // Now delete the file and see what happens
    [cacheIndex removeEntryForKey:@"test1"];
    dispatch_sync(cacheIndex.databaseQueue, ^{});
    dispatch_sync(_fileQueue, ^{});

    BOOL fileExists = [[NSFileManager defaultManager]
                       fileExistsAtPath:filePath];
    XCTAssertFalse(fileExists, @"File wasn't deleted at %@", filePath);
    XCTAssertEqual(
                   dataFromFile.length,
                   dummyData.length,
                   @"Read something different from what wrote");

    stringFromFile = [[NSString alloc]
                      initWithData:dataFromFile
                      encoding:NSUTF8StringEncoding];
    XCTAssertTrue(
                 [stringFromFile isEqualToString:dummy],
                 @"Payload doesn't match!");

    [cacheIndex release];
    [[NSFileManager defaultManager] removeItemAtPath:tempFolder error:NULL];
}

- (void)testBasicFriendPickerCache {

    // let's get a user going with some friends
    FBTestSession *session1 = self.defaultTestSession;
    FBTestSession *session2 = [self getSessionWithSharedUserWithPermissions:nil
                                                              uniqueUserTag:kSecondTestUserTag];
    [self makeTestUserInSession:session1 friendsWithTestUserInSession:session2];

    FBTestSession *session3 = [self getSessionWithSharedUserWithPermissions:nil
                                                              uniqueUserTag:kThirdTestUserTag];
    [self makeTestUserInSession:session1 friendsWithTestUserInSession:session3];

    FBCacheDescriptor *cacheDescriptor = [FBFriendPickerViewController cacheDescriptor];

    // set the page limit to 1
    //[cacheDescriptor performSelector:@selector(setUsePageLimitOfOne)];

    // here we actually perform the prefetch
    [cacheDescriptor prefetchAndCacheForSession:session1];

    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];

    [blocker waitWithPeriodicHandler:^(FBTestBlocker *innerBlocker) {
        // white-box, using an internal API to determine if fetch completed
        if ([cacheDescriptor performSelector:@selector(hasCompletedFetch)]) {
            [innerBlocker signal];
        }
    }];
    [blocker release];
    blocker = [[FBTestBlocker alloc] init];
    
    FBFriendPickerViewController *vc = [[FBFriendPickerViewController alloc] init];
    vc.session = session1;
    [vc configureUsingCachedDescriptor:cacheDescriptor];
    
    FBRequest *request = [vc performSelector:@selector(requestForLoadData)];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    [connection addRequest:request
         completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
             [blocker signal];
             XCTAssertTrue(innerConnection.isResultFromCache, @"This result should have been cached");
         }];
    
    [connection startWithCacheIdentity:FBFriendPickerCacheIdentity
                 skipRoundtripIfCached:YES];
    
    XCTAssertTrue([blocker waitWithTimeout:30], @"blocker timed out");
    
    [blocker release];
    
    [connection release];
}

@end

#endif

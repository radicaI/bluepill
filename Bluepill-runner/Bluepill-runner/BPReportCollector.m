//  Copyright 2016 LinkedIn Corporation
//  Licensed under the BSD 2-Clause License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://opensource.org/licenses/BSD-2-Clause
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.

#import "BPReportCollector.h"
#import <BluepillLib/BPUtils.h>

@implementation BPReportCollector

+ (void)collectReportsFromPath:(NSString *)reportsPath
             onReportCollected:(void (^)(NSURL *fileUrl))fileHandler
                   applyXQuery:(NSString *)XQuery
                  withOutputAtPath:(NSString *)finalReportPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSURL *directoryURL = [NSURL fileURLWithPath:reportsPath isDirectory:YES];
    NSArray *keys = [NSArray arrayWithObject:NSURLIsDirectoryKey];
    NSDirectoryEnumerator *enumerator = [fileManager
                                         enumeratorAtURL:directoryURL
                                         includingPropertiesForKeys:keys
                                         options:0
                                         errorHandler:^(NSURL *url, NSError *error) {
                                             fprintf(stderr, "Failed to process url %s", [[url absoluteString] UTF8String]);
                                             return YES;
                                         }];

    NSMutableArray *nodesArray = [NSMutableArray new];
    NSMutableDictionary *testStats = [NSMutableDictionary new];
    int totalTests = 0;
    int totalErrors = 0;
    int totalFailures = 0;
    double totalTime = 0;

    for (NSURL *url in enumerator) {
        NSError *error;
        NSNumber *isDirectory = nil;
        if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
            fprintf(stderr, "Failed to get resource from url %s", [[url absoluteString] UTF8String]);
        }
        else if (![isDirectory boolValue]) {
            if ([[url pathExtension] isEqualToString:@"xml"]) {
                // Skipping over the failure logs for the total report
                // so it only contains successes to maintain existing functionality
                // todo: These logs actually need to be parsed for just the
                // successes and added to the final report
                if (!XQuery && [[url lastPathComponent] containsString:@"failure"]) {
                    continue;
                }
                
                NSError *error;
                NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:&error];
                if (error) {
                    [BPUtils printInfo:ERROR withString:@"Failed to parse %@: %@", url, error.localizedDescription];
                    // When app crash before test start, it can result in empty xml file
                    // Test results from other BP workers should continue to parse
                    continue;
                }
                
                NSArray *testsuiteNodes = nil;
                if (XQuery) {
                    // <testsuites> refer to each .xctest run, while the first <testsuite> refers to the bundle and the second <testsuite> refers to each file in that bundle. The provided XQuery string will filter down to specific testcases based on what they contain.
                    testsuiteNodes = [doc objectsForXQuery:[NSString stringWithFormat:@".//testsuites/testsuite/testsuite/%@/../..", XQuery] error:&error];
                    for (NSXMLElement *element in testsuiteNodes) {
                        totalTests += [[[element attributeForName:@"tests"] stringValue] integerValue];
                        totalErrors += [[[element attributeForName:@"errors"] stringValue] integerValue];
                        totalFailures += [[[element attributeForName:@"failures"] stringValue] integerValue];
                        totalTime += [[[element attributeForName:@"time"] stringValue] doubleValue];
                    }
                    
                } else {
                    // Don't withhold the parent object.
                    @autoreleasepool {
                        NSArray *testsuitesNodes =  [doc nodesForXPath:[NSString stringWithFormat:@".//%@", @"testsuites"] error:&error];
                        for (NSXMLElement *element in testsuitesNodes) {
                            totalTests += [[[element attributeForName:@"tests"] stringValue] integerValue];
                            totalErrors += [[[element attributeForName:@"errors"] stringValue] integerValue];
                            totalFailures += [[[element attributeForName:@"failures"] stringValue] integerValue];
                            totalTime += [[[element attributeForName:@"time"] stringValue] doubleValue];
                        }
                    }
                    
                    testsuiteNodes = [doc nodesForXPath:[NSString stringWithFormat:@".//%@/testsuite", @"testsuites"] error:&error];
                }
                
                [nodesArray addObjectsFromArray:testsuiteNodes];
                if (fileHandler) {
                    fileHandler(url);
                }
            }
        }
    }

    testStats[@"name"] = @"Selected tests";
    testStats[@"tests"] = [@(totalTests) stringValue];
    testStats[@"errors"] = [@(totalErrors) stringValue];
    testStats[@"failures"] = [@(totalFailures) stringValue];
    testStats[@"time"] = [@(totalTime) stringValue];
    NSXMLElement *rootTestSuites = [[NSXMLElement alloc] initWithName:@"testsuites"];
    [rootTestSuites setAttributesWithDictionary:testStats];
    [rootTestSuites setChildren:nodesArray];
    NSXMLDocument *xmlRequest = [NSXMLDocument documentWithRootElement:rootTestSuites];
    NSData *xmlData = [xmlRequest XMLDataWithOptions:NSXMLDocumentIncludeContentTypeDeclaration];
    [xmlData writeToFile:finalReportPath atomically:YES];
}

+ (void)collectReportsFromPath:(NSString *)reportsPath
                                            withOtherData:(NSDictionary *)otherData
                                              applyXQuery:(NSString *)XQuery
                                            hideSuccesses:(BOOL)hideSuccesses
                                     withTraceEventAtPath:(NSString *)finalReportPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSURL *directoryURL = [NSURL fileURLWithPath:reportsPath isDirectory:YES];
    NSArray *keys = [NSArray arrayWithObject:NSURLIsDirectoryKey];
    NSDirectoryEnumerator *enumerator = [fileManager
                                         enumeratorAtURL:directoryURL
                                         includingPropertiesForKeys:keys
                                         options:0
                                         errorHandler:^(NSURL *url, NSError *error) {
                                             fprintf(stderr, "Failed to process url %s", [[url absoluteString] UTF8String]);
                                             return YES;
                                         }];
    TraceEvent *traceEvent = [[TraceEvent alloc] initWithData:otherData];
    NSCharacterSet* notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *currentSim = @"-1";

    for (NSURL *url in enumerator) {
        NSError *error;
        NSNumber *isDirectory = nil;
        NSString *currentFolder = nil;
        if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
            fprintf(stderr, "Failed to get resource from url %s", [[url absoluteString] UTF8String]);
        }
        // Getting which sim # folder we're currently in so we can attach that to all the tests in that folder
        else if ([isDirectory boolValue]) {
            currentFolder = [url pathComponents][[[url pathComponents] count] - 1 ];
            if ([currentFolder rangeOfCharacterFromSet:notDigits].location == NSNotFound) {
                currentSim = currentFolder;
            }
        }
        else if (![isDirectory boolValue]) {
            if ([[url pathExtension] isEqualToString:@"xml"]) {
                NSError *error;
                NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:&error];
                if (error) {
                    [BPUtils printInfo:ERROR withString:@"Failed to parse %@: %@", url, error.localizedDescription];
                    // When app crash before test start, it can result in empty xml file
                    // Test results from other BP workers should continue to parse
                    continue;
                }

                NSArray *testsuitesNodes = [doc objectsForXQuery:XQuery error:&error];
                NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZ"];
                NSDate *currentTime = nil;

                for (NSXMLElement *testsuite in testsuitesNodes) {
                    currentTime = [dateFormatter dateFromString:[[testsuite attributeForName:@"timestamp"] stringValue]];
                    for (NSXMLElement *testcaseChild in [testsuite children]) {

                        // Tests with errors or failures will have more than 1 child node
                        if (hideSuccesses && [testcaseChild childCount] == 1) {
                            continue;
                        }

                        NSString *testName = [[testcaseChild attributeForName:@"name"] stringValue];
                        NSString *className = [[testcaseChild attributeForName:@"classname"] stringValue];
                        NSInteger timestamp = [[NSString stringWithFormat:@"%f", [currentTime timeIntervalSince1970] * 1000] integerValue];
                        float duration = [[[testcaseChild attributeForName:@"time"] stringValue] floatValue];
                        NSDictionary *args = [[NSDictionary alloc] initWithObjectsAndKeys:
                                              currentSim, @"simNum",
                                              nil];

                        [traceEvent appendCompleteTraceEvent:[NSString stringWithFormat:@"%@/%@", className, testName] :className :timestamp :duration :0 :0 :args];
                        currentTime = [currentTime dateByAddingTimeInterval:duration];
                    }
                }
            }
        }
    }
    NSError *error;
    NSDictionary *traceEventDict = [traceEvent toDict];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:traceEventDict options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [jsonString writeToFile:finalReportPath atomically:YES encoding:NSUTF8StringEncoding error:&error];

}

@end

@implementation TraceEvent
- (instancetype)init {
    self = [self initWithData:nil];
    return self;
}

- (instancetype)initWithData:(NSDictionary *)data {
    self = [super init];
    if (self) {
        _displayTimeUnit = @"ns";
        _systemTraceEvents = @"SystemTraceData";
        _otherData = data;
        _stackFrames = [[NSDictionary alloc] init];
        _samples = [NSMutableArray array];
        _traceEvents = [NSMutableArray array];
    }
    return self;
}

- (void)appendCompleteTraceEvent:(NSString *)name
                                        :(NSString *)cat
                                        :(NSInteger)ts
                                        :(float)dur
                                        :(NSInteger)pid
                                        :(NSInteger)tid
                                        :(NSDictionary *)args {
    NSDictionary *newTraceEvent = [[NSDictionary alloc] initWithObjectsAndKeys:
     name, @"name",
     cat, @"cat",
     @"X", @"ph", // Complete event type (with both a timestamp and duration)
     [NSString stringWithFormat: @"%ld", (long)ts], @"ts",
     [[NSNumber numberWithFloat:dur] stringValue], @"dur",
     [NSString stringWithFormat: @"%ld", (long)pid], @"pid",
     [NSString stringWithFormat: @"%ld", (long)tid], @"tid",
     args, @"args",
     nil];

    [_traceEvents addObject:newTraceEvent];
}
- (NSDictionary *)toDict {
    return [[NSDictionary alloc] initWithObjectsAndKeys:
            _displayTimeUnit, @"displayTimeUnit",
            _systemTraceEvents, @"systemTraceEvents",
            _otherData, @"otherData",
            _stackFrames, @"stackFrames",
            _samples, @"samples",
            _traceEvents, @"traceEvents",
            nil];
}
@end

//  Copyright 2016 LinkedIn Corporation
//  Licensed under the BSD 2-Clause License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://opensource.org/licenses/BSD-2-Clause
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.

#import "BPReportCollector.h"
#import "BPTraceEvent.h"
#import <BluepillLib/BPUtils.h>

@implementation BPReportCollector

+ (void)collectReportsFromPath:(NSString *)reportsPath
             onReportCollected:(void (^)(NSURL *fileUrl))fileHandler
                  outputAtPath:(NSString *)finalReportPath {
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
                NSError *error;
                NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:&error];
                if (error) {
                    [BPUtils printInfo:ERROR withString:@"Failed to parse %@: %@", url, error.localizedDescription];
                    // When app crash before test start, it can result in empty xml file
                    // Test results from other BP workers should continue to parse
                    continue;
                }

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

                NSArray *testsuiteNodes =
                [doc nodesForXPath:[NSString stringWithFormat:@".//%@/testsuite", @"testsuites"] error:&error];

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
        } else if ([isDirectory boolValue]) {
            // Getting which sim # folder we're currently in so we can attach that to all the tests in that folder
            currentFolder = [url pathComponents][[[url pathComponents] count] - 1];
            if ([currentFolder rangeOfCharacterFromSet:notDigits].location == NSNotFound) {
                currentSim = currentFolder;
            }
        } else if (![isDirectory boolValue]) {
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

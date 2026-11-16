#import <Foundation/Foundation.h>
#include "benchmark.h"

NSDictionary *MBPointRecord(mb_result result);
BOOL MBDecodePoint(id record, mb_result *result);
BOOL MBComparable(NSDictionary *current, NSDictionary *baseline);
NSString *MBCSV(NSDictionary *report);
BOOL MBValidReport(id report);

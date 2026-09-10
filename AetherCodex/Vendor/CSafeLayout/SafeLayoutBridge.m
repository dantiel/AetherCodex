#import "include/SafeLayoutBridge.h"
#import <AppKit/AppKit.h>

NSRange SafeCharacterRangeForGlyphRange(NSLayoutManager *lm, NSRange glyphRange) {
    if (lm == nil || glyphRange.location == NSNotFound || glyphRange.length == 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    if (NSMaxRange(glyphRange) > lm.numberOfGlyphs) {
        return NSMakeRange(NSNotFound, 0);
    }
    @try {
        return [lm characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] characterRangeForGlyphRange caught: %@", e.name);
        return NSMakeRange(NSNotFound, 0);
    }
}

NSUInteger SafeGlyphIndexForCharacter(NSLayoutManager *lm, NSUInteger charIndex) {
    if (lm == nil || charIndex == NSNotFound) {
        return NSNotFound;
    }
    if (charIndex >= lm.textStorage.length) {
        return NSNotFound;
    }
    @try {
        return [lm glyphIndexForCharacterAtIndex:charIndex];
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] glyphIndexForCharacter caught: %@", e.name);
        return NSNotFound;
    }
}

NSRect SafeLineFragmentRect(NSLayoutManager *lm, NSUInteger glyphIndex,
                             NSRangePointer effectiveGlyphRange) {
    if (lm == nil || glyphIndex == NSNotFound || glyphIndex >= lm.numberOfGlyphs) {
        if (effectiveGlyphRange) *effectiveGlyphRange = NSMakeRange(NSNotFound, 0);
        return NSZeroRect;
    }
    @try {
        return [lm lineFragmentRectForGlyphAtIndex:glyphIndex
                                    effectiveRange:effectiveGlyphRange
                            withoutAdditionalLayout:YES];
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] lineFragmentRectForGlyphAt caught: %@", e.name);
        if (effectiveGlyphRange) *effectiveGlyphRange = NSMakeRange(NSNotFound, 0);
        return NSZeroRect;
    }
}

NSRange SafeGlyphRangeForCharacterRange(NSLayoutManager *lm,
                                         NSRange charRange,
                                         NSRangePointer actualCharRange) {
    if (lm == nil || charRange.location == NSNotFound) {
        return NSMakeRange(NSNotFound, 0);
    }
    if (charRange.location > lm.textStorage.length) {
        return NSMakeRange(NSNotFound, 0);
    }
    if (NSMaxRange(charRange) > lm.textStorage.length) {
        return NSMakeRange(NSNotFound, 0);
    }
    if (lm.numberOfGlyphs == 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    @try {
        NSRange r = [lm glyphRangeForCharacterRange:charRange
                               actualCharacterRange:actualCharRange];
        if (r.location != NSNotFound && NSMaxRange(r) > lm.numberOfGlyphs) {
            return NSMakeRange(NSNotFound, 0);
        }
        return r;
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] glyphRangeForCharacterRange caught: %@", e.name);
        return NSMakeRange(NSNotFound, 0);
    }
}

NSRect SafeBoundingRectForGlyphRange(NSLayoutManager *lm,
                                       NSRange glyphRange,
                                       NSTextContainer *tc) {
    if (lm == nil || tc == nil) return NSZeroRect;
    if (glyphRange.location == NSNotFound || glyphRange.length == 0) return NSZeroRect;
    if (NSMaxRange(glyphRange) > lm.numberOfGlyphs) return NSZeroRect;
    @try {
        return [lm boundingRectForGlyphRange:glyphRange inTextContainer:tc];
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] boundingRectForGlyphRange caught: %@", e.name);
        return NSZeroRect;
    }
}

NSRange SafeGlyphRangeForBoundingRect(NSLayoutManager *lm,
                                        NSRect rect,
                                        NSTextContainer *tc) {
    if (lm == nil || tc == nil) return NSMakeRange(NSNotFound, 0);
    if (lm.numberOfGlyphs == 0) return NSMakeRange(NSNotFound, 0);
    @try {
        NSRange r = [lm glyphRangeForBoundingRect:rect inTextContainer:tc];
        if (r.location != NSNotFound && NSMaxRange(r) > lm.numberOfGlyphs) {
            return NSMakeRange(NSNotFound, 0);
        }
        return r;
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] glyphRangeForBoundingRect caught: %@", e.name);
        return NSMakeRange(NSNotFound, 0);
    }
}

NSPoint SafeLocationForGlyphAtIndex(NSLayoutManager *lm, NSUInteger glyphIndex) {
    if (lm == nil || glyphIndex == NSNotFound || glyphIndex >= lm.numberOfGlyphs) {
        return NSZeroPoint;
    }
    @try {
        return [lm locationForGlyphAtIndex:glyphIndex];
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] locationForGlyphAtIndex caught: %@", e.name);
        return NSZeroPoint;
    }
}

BOOL SafeCallBlock(void (^block)(void)) {
    if (block == nil) return YES;
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[SafeLayout] SafeCallBlock caught: %@ — %@", e.name, e.reason);
        return NO;
    }
}
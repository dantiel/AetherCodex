#include <Foundation/Foundation.h>

@class NSLayoutManager;
@class NSTextContainer;

/// Exception-safe: returns character range for glyph range,
/// or {NSNotFound, 0} if the layout manager throws internally.
NSRange SafeCharacterRangeForGlyphRange(NSLayoutManager * _Nonnull lm, NSRange glyphRange);

/// Exception-safe: returns glyph index for character index,
/// or NSNotFound if the layout manager throws internally.
NSUInteger SafeGlyphIndexForCharacter(NSLayoutManager * _Nonnull lm, NSUInteger charIndex);

/// Exception-safe: returns line fragment rect for glyph index,
/// or NSZeroRect if the layout manager throws internally.
/// effectiveGlyphRange (if non-NULL) is set to {NSNotFound,0} on failure.
NSRect SafeLineFragmentRect(NSLayoutManager * _Nonnull lm, NSUInteger glyphIndex,
                             NSRangePointer _Nullable effectiveGlyphRange);

/// Exception-safe: returns glyph range for character range,
/// or {NSNotFound, 0} if the layout manager throws internally.
NSRange SafeGlyphRangeForCharacterRange(NSLayoutManager * _Nonnull lm,
                                         NSRange charRange,
                                         NSRangePointer _Nullable actualCharRange);

/// Exception-safe: returns bounding rect for glyph range,
/// or NSZeroRect if the layout manager throws internally.
NSRect SafeBoundingRectForGlyphRange(NSLayoutManager * _Nonnull lm,
                                       NSRange glyphRange,
                                       NSTextContainer * _Nonnull tc);

/// Exception-safe: returns glyph range for bounding rect,
/// or {NSNotFound, 0} if the layout manager throws internally.
NSRange SafeGlyphRangeForBoundingRect(NSLayoutManager * _Nonnull lm,
                                        NSRect rect,
                                        NSTextContainer * _Nonnull tc);

/// Exception-safe: returns location for glyph index,
/// or NSZeroPoint if the layout manager throws internally.
NSPoint SafeLocationForGlyphAtIndex(NSLayoutManager * _Nonnull lm, NSUInteger glyphIndex);

/// Catch-all: executes a block inside @try/@catch, returning NO on exception.
/// Use to protect super.drawBackground, super.drawGlyphs, etc.
BOOL SafeCallBlock(void (^_Nonnull block)(void));
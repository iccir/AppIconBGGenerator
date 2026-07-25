#import "AppDelegate.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


static CGImageRef sCreateImage(
    size_t width, size_t height, size_t bytesPerRow,
    CGBitmapInfo bitmapInfo, CFStringRef colorSpaceName,
    void (^callback)(CGContextRef)
) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(colorSpaceName);

    CGContextRef cgContext = CGBitmapContextCreate(
        NULL, width, height,
        8, bytesPerRow, colorSpace, bitmapInfo
    );

    CGImageRef cgImage = NULL;

    if (cgContext) {
        NSGraphicsContext *savedContext = [NSGraphicsContext currentContext];
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:cgContext flipped:NO];

        [NSGraphicsContext setCurrentContext:context];
        if (callback) callback(cgContext);
        [NSGraphicsContext setCurrentContext:savedContext];
            
        cgImage = CGBitmapContextCreateImage(cgContext);
        CFRelease(cgContext);
    }

    CGColorSpaceRelease(colorSpace);
    
    return cgImage;
}
    



static CGImageRef sCreateRGBImage(
    size_t width, size_t height, BOOL opaque,
    void (^callback)(CGContextRef)
) {
    CFStringRef spaceName = kCGColorSpaceSRGB;
    
    CGBitmapInfo bitmapInfo = 0 |
        (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst) |
        kCGImageByteOrder32Little;

    return sCreateImage(width, height, width * 4, bitmapInfo, spaceName, callback);
}


static CGImageRef sCreateGrayscaleImage(
    size_t width, size_t height, BOOL opaque,
    void (^callback)(CGContextRef)
) {
    CFStringRef spaceName = kCGColorSpaceGenericGrayGamma2_2;

    CGBitmapInfo bitmapInfo = 0 |
        (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);

    return sCreateImage(width, height, width * 2, bitmapInfo, spaceName, callback);
}


static BOOL sWriteImage(CGImageRef image, NSURL *fileURL)
{
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef) fileURL,
        (__bridge CFStringRef) [UTTypePNG identifier],
        1,
        NULL
    );

    if (!destination) return NO;

    CGImageDestinationAddImage(destination, image, NULL);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    
    return ok;
}


static BOOL sDetectOpaqueEdge(size_t width, size_t height, uint32_t *buffer, NSInteger *outX)
{
    size_t y = height / 2;
    BOOL foundOpaquePixel = NO;
    size_t leftmostOpaqueX = 0;

    for (size_t x = width - 1; x > 0; x--) {
        uint32_t pixel = buffer[y * width + x];
        BOOL isOpaque = (pixel & 0xff000000) == 0xff000000;

        if (isOpaque) {
            leftmostOpaqueX = x;
            foundOpaquePixel = YES;
        }
    }
    
    if (foundOpaquePixel) {
        if (outX) *outX = leftmostOpaqueX;
    }

    return foundOpaquePixel;
}


static CGImageRef sCreateExtendedImage(CGImageRef inImage)
{
    size_t width  = CGImageGetWidth(inImage);
    size_t height = CGImageGetHeight(inImage);

    size_t bufferLength = width * height * 4;
    uint32_t *buffer = calloc(1, bufferLength);

    // Draw image into buffer
    {
        CGImageRef tmpImage = sCreateRGBImage(width, height, NO, ^(CGContextRef context) {
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), inImage);
            memcpy(buffer, CGBitmapContextGetData(context), bufferLength);
        });
        CGImageRelease(tmpImage);
    }
    
    __auto_type isOpaque = ^(uint32_t pixel) {
        return (pixel & 0xff000000) == 0xff000000;
    };
    
    __auto_type unpremultiply = ^(uint32_t pixel) {
        uint32_t a = (pixel >> 24) & 0xff;
        uint32_t r = (pixel >> 16) & 0xff;
        uint32_t g = (pixel >>  8) & 0xff;
        uint32_t b =  pixel        & 0xff;

        if (a != 0) {
            r = MIN(255, (r * 255 + a / 2) / a);
            g = MIN(255, (g * 255 + a / 2) / a);
            b = MIN(255, (b * 255 + a / 2) / a);

            pixel = 0xFF000000 | (r << 16) | (g << 8) | b;
        }

        return pixel;
    };

    __auto_type bleed = ^() {
        uint32_t *tmp = malloc(width * height * 4);
        memcpy(tmp, buffer, bufferLength);
        
        for (size_t y = 1; y < (height - 1); y++) {
            for (size_t x = 1; x < (width - 1); x++) {
                uint32_t pixel = tmp[y * width + x];

                if (!isOpaque(pixel)) {
                    // Take lightest opaque neighbor
                    uint32_t neighbors[8] = {
                        tmp[(y - 1) * width + (x - 1)],
                        tmp[(y - 1) * width + (x    )],
                        tmp[(y - 1) * width + (x + 1)],
                        tmp[(y    ) * width + (x - 1)],
                        tmp[(y    ) * width + (x + 1)],
                        tmp[(y + 1) * width + (x - 1)],
                        tmp[(y + 1) * width + (x    )],
                        tmp[(y + 1) * width + (x + 1)]
                    };

                    for (size_t i = 0; i < 8; i++) {
                        if (neighbors[i] >= 0xFF000000) {
                            pixel = MAX(neighbors[i], pixel);
                        }
                    }
                    
                    if (isOpaque(pixel)) {
                        // See if unpremultiplied version is lighter
                        uint32_t opaquePixel = unpremultiply(pixel);
                        pixel = MAX(opaquePixel, pixel);
                        
                        buffer[y * width + x] = pixel;
                    }
                }
            }
        }
        
        free(tmp);
    };

    __auto_type extendLeft = ^() {
        for (size_t y = 0; y < height; y++) {
            ssize_t x = 0;
            uint32_t opaquePixel = 0;

            while (x < width) {
                uint32_t pixel = buffer[y * width + x];

                if (isOpaque(pixel)) {
                    opaquePixel = pixel;
                    break;
                }

                x++;
            }
            
            if (opaquePixel) {
                while (--x >= 0) {
                    buffer[y * width + x] = opaquePixel;
                }
            }
        }
    };

    __auto_type extendRight = ^() {
        for (size_t y = 0; y < height; y++) {
            ssize_t x = (ssize_t)width - 1;
            uint32_t opaquePixel = 0;

            while (x >= 0) {
                uint32_t pixel = buffer[y * width + x];

                if (isOpaque(pixel)) {
                    opaquePixel = pixel;
                    break;
                }
                
                x--;
            }
            
            if (opaquePixel) {
                while (++x < width) {
                    buffer[y * width + x] = opaquePixel;
                }
            }
        }
    };

    bleed();
    bleed();
    
    extendLeft();
    extendRight();

    CGImageRef result = sCreateRGBImage(width, height, NO, ^(CGContextRef context) {
        memcpy(CGBitmapContextGetData(context), buffer, bufferLength);
    });

    free(buffer);
    
    return result;
}





@interface AppDelegate ()

@property (strong) IBOutlet NSWindow *window;

@property (nonatomic, weak) IBOutlet NSTextField *widthHeightField;

@end

@implementation AppDelegate {
    void *_appIconBuffer;
    CGImageRef _appIconCGImage;
}

- (void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSImage *appIconImage = [NSApp applicationIconImage];
    BOOL found256 = NO;

    for (NSImageRep *rep in [appIconImage representations]) {
        if ([rep pixelsWide] == 256 && [rep pixelsHigh] == 256) {
            found256 = YES;
            break;
        }
    }
        
    if (!found256) {
        NSAlert *alert = [[NSAlert alloc] init];
        
        [alert setMessageText:@"Could not find a 256x256 application icon."];
        [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse returnCode) {
            [NSApp terminate:self];
        }];
        
        return;
    }
    
    uint32_t *buffer = malloc(256 * 256 * 4);
    _appIconCGImage = sCreateRGBImage(256, 256, NO, ^(CGContextRef context) {
        [appIconImage drawInRect:CGRectMake(0, 0, 256, 256)];
        memcpy(buffer, CGBitmapContextGetData(context), 256 * 256 * 4);
    });
    
    sleep(1);
    NSInteger detectedX = 0;
    if (sDetectOpaqueEdge(256, 256, buffer, &detectedX)) {
        NSInteger squircleWidth = 256 - (detectedX * 2);
        NSLog(@"%ld %ld", detectedX, squircleWidth);

        [_widthHeightField setIntegerValue:squircleWidth];
    } else {
        [_widthHeightField setIntegerValue:256];
    }
    
    free(buffer);
    
}


- (BOOL) applicationSupportsSecureRestorableState:(NSApplication *)app
{
    return YES;
}


- (IBAction) generateImage:(id)sender
{
    if (!_appIconCGImage) return;

    CGImageRef extendedImage = sCreateExtendedImage(_appIconCGImage);

    size_t outputWidth  = [_widthHeightField integerValue];
    if (!outputWidth) outputWidth = 256;

    size_t outputHeight = outputWidth;

    CGImageRef outImage = extendedImage ? sCreateGrayscaleImage(
        outputWidth, outputHeight, YES,
        ^(CGContextRef context)
    {
        size_t extendedWidth = CGImageGetWidth( extendedImage);
        size_t extendedHeight = CGImageGetWidth( extendedImage);
        
        CGRect frame = CGRectMake(
            ((double)outputWidth  - extendedWidth ) / 2.0,
            ((double)outputHeight - extendedHeight) / 2.0,
            extendedWidth, extendedHeight
        );
        
        if (extendedImage) {
            CGContextDrawImage(context, frame, extendedImage);
        }
    }) : NULL;

    CGImageRelease(extendedImage);

    NSURL *tmpURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSURL *outputURL = [tmpURL URLByAppendingPathComponent:@"output.png"];

    BOOL ok = outImage && sWriteImage(outImage, outputURL);
    
    CGImageRelease(outImage);

    if (ok) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ outputURL ]];

    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        
        [alert setMessageText:@"Could not write image."];
        [alert beginSheetModalForWindow:_window completionHandler:nil];
    }
}


@end

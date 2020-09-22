/*
Copyright © 2019 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

Abstract:
Defines a function which extracts the smallest and largest values from a pixel buffer.
*/

#ifndef minMaxFromBuffer_h
#define minMaxFromBuffer_h

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

void minMaxFromPixelBuffer(CVPixelBufferRef pixelBuffer, float* minValue, float* maxValue, MTLPixelFormat pixelFormat);

#endif /* minMaxFromBuffer_h */

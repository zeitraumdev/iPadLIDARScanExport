/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A view implementing point cloud rendering
*/

#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <Foundation/Foundation.h>
#include "PointCloudMetalView.h"
#import "AAPLTransforms.h"
#include <simd/simd.h>

simd::float3 matrix4_mul_vector3(simd::float4x4 m, simd::float3 v) {
    simd::float4 temp = { v.x, v.y, v.z, 0.0f };
    temp = simd_mul(m, temp);
    return { temp.x, temp.y, temp.z };
}

@implementation PointCloudMetalView {
    dispatch_queue_t _syncQueue;
    AVDepthData* _internalDepthFrame;
    CVPixelBufferRef _internalColorTexture;
    CVMetalTextureCacheRef _depthTextureCache;
    CVMetalTextureCacheRef _colorTextureCache;
    simd::float3 _center;   // current point camera looks at
    simd::float3 _eye;      // current camera position
    simd::float3 _up;       // camera "up" direction

    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _renderPipelineState;
    id<MTLDepthStencilState> _depthStencilState;
}

- (nonnull instancetype)initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    [self internalInit];
    return self;
}

- (nonnull instancetype)initWithCoder:(nonnull NSCoder *)coder {
    self = [super initWithCoder:coder];
    self.device = MTLCreateSystemDefaultDevice();
    [self internalInit];
    return self;
}

- (void)internalInit {
    dispatch_queue_attr_t attr = NULL;
    attr = dispatch_queue_attr_make_with_autorelease_frequency(attr, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INITIATED, 0);
    _syncQueue = dispatch_queue_create("PointCloudMetalView sync queue", attr);
    
    [self configureMetal];
    
    CVMetalTextureCacheCreate(NULL, NULL, self.device, NULL, &_depthTextureCache);
    CVMetalTextureCacheCreate(NULL, NULL, self.device, NULL, &_colorTextureCache);

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    
    [self resetView];
}

- (void)configureMetal {
    // Load all the shader files with a metal file extension in the project
    id<MTLLibrary> defaultLibrary = [self.device newDefaultLibrary];

    // Load the vertex function from the library
    id <MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShaderPoints"];
    
    // Load the fragment function from the library
    id <MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentShaderPoints"];

    // Set up a descriptor for creating a pipeline state object
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"Texturing Pipeline";
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    MTLDepthStencilDescriptor *piplineDepthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    piplineDepthDescriptor.depthWriteEnabled = true;
    piplineDepthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    _depthStencilState = [self.device newDepthStencilStateWithDescriptor:piplineDepthDescriptor];
    
    NSError *error = NULL;
    _renderPipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                       error:&error];

    if (!_renderPipelineState)
    {
        // Pipeline State creation could fail if we haven't properly set up our pipeline descriptor.
        // If the Metal API validation is enabled, we can find out more information about what
        // went wrong.  (Metal API validation is enabled by default when a debug build is run
        // from Xcode)
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    // Create the command queue
    _commandQueue = [self.device newCommandQueue];
}

- (void)setDepthFrame:(AVDepthData* _Nonnull)depth withTexture:(_Nonnull CVPixelBufferRef)unormTexture {
    dispatch_sync(_syncQueue, ^{
        self->_internalDepthFrame = depth;
        CVPixelBufferRelease(self->_internalColorTexture);
        self->_internalColorTexture = unormTexture;
        CVPixelBufferRetain(self->_internalColorTexture);
    });
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
    });
}

- (void)drawRect:(CGRect)rect {
    __block AVDepthData* depthData = nil;
    __block CVPixelBufferRef colorFrame = nullptr;
    
    dispatch_sync(_syncQueue, ^{
        depthData = self->_internalDepthFrame;
        colorFrame = self->_internalColorTexture;
        CVPixelBufferRetain(colorFrame);
    });
    
    if (depthData == nil || colorFrame == nullptr)
        return;

    // Create a Metal texture from the depth frame
    CVPixelBufferRef depthFrame = depthData.depthDataMap;
    CVMetalTextureRef cvDepthTexture = nullptr;
    if (kCVReturnSuccess != CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                            _depthTextureCache,
                            depthFrame,
                            nil,
                            MTLPixelFormatR16Float,
                            CVPixelBufferGetWidth(depthFrame),
                            CVPixelBufferGetHeight(depthFrame),
                            0,
                            &cvDepthTexture)) {
        NSLog(@"Failed to create depth texture");
        CVPixelBufferRelease(colorFrame);
        return;
    }
    
    id<MTLTexture> depthTexture = CVMetalTextureGetTexture(cvDepthTexture);
    
    // Create a Metal texture from the color texture
    CVMetalTextureRef cvColorTexture = nullptr;
    if (kCVReturnSuccess != CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                            _colorTextureCache,
                            colorFrame,
                            nil,
                            MTLPixelFormatBGRA8Unorm,
                            CVPixelBufferGetWidth(colorFrame),
                            CVPixelBufferGetHeight(colorFrame),
                            0,
                            &cvColorTexture)) {
        NSLog(@"Failed to create color texture");
        CVPixelBufferRelease(colorFrame);
        return;
    }
    
    id<MTLTexture> colorTexture = CVMetalTextureGetTexture(cvColorTexture);
    
    matrix_float3x3 intrinsics = depthData.cameraCalibrationData.intrinsicMatrix;
    CGSize referenceDimensions = depthData.cameraCalibrationData.intrinsicMatrixReferenceDimensions;

    float ratio = referenceDimensions.width / CVPixelBufferGetWidth(depthFrame);
    intrinsics.columns[0][0] /= ratio;
    intrinsics.columns[1][1] /= ratio;
    intrinsics.columns[2][0] /= ratio;
    intrinsics.columns[2][1] /= ratio;
    
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    
    // Obtain a renderPassDescriptor generated from the view's drawable textures
    MTLRenderPassDescriptor *renderPassDescriptor = self.currentRenderPassDescriptor;
    
    if(renderPassDescriptor != nil) {
        MTLTextureDescriptor* depthTextureDescriptor = [[MTLTextureDescriptor alloc] init];
        depthTextureDescriptor.width = self.drawableSize.width;
        depthTextureDescriptor.height = self.drawableSize.height;
        depthTextureDescriptor.pixelFormat = MTLPixelFormatDepth32Float;
        depthTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        
        id<MTLTexture> depthTestTexture = [self.device newTextureWithDescriptor:depthTextureDescriptor];

        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        renderPassDescriptor.depthAttachment.clearDepth = 1.0;
        renderPassDescriptor.depthAttachment.texture = depthTestTexture;
        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setDepthStencilState:_depthStencilState];
        [renderEncoder setRenderPipelineState:_renderPipelineState];

        // set arguments to shader
        [renderEncoder setVertexTexture:depthTexture atIndex:0];

        simd::float4x4 finalViewMatrix = [self getFinalViewMatrix];

        [renderEncoder setVertexBytes:&finalViewMatrix length:sizeof(finalViewMatrix) atIndex:0];
        [renderEncoder setVertexBytes:&intrinsics length:sizeof(intrinsics) atIndex:1];

        [renderEncoder setFragmentTexture:colorTexture atIndex:0];

        [renderEncoder drawPrimitives:MTLPrimitiveTypePoint
                          vertexStart:0
                          vertexCount:CVPixelBufferGetWidth(depthFrame) * CVPixelBufferGetHeight(depthFrame)];
        
        [renderEncoder endEncoding];
        
        // Schedule a present once the framebuffer is complete using the current drawable
        [commandBuffer presentDrawable:self.currentDrawable];
    }
    
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];

    CFRelease(cvDepthTexture);
    CFRelease(cvColorTexture);
    CVPixelBufferRelease(colorFrame);
}

- (void)rollAroundCenter:(float)angle {
    dispatch_sync(_syncQueue, ^{
        simd::float3 viewDir = self->_center - self->_eye;
        viewDir = simd::normalize(viewDir);
        simd::float4x4 rotMat = AAPL::rotate(angle, viewDir);
        self->_up = matrix4_mul_vector3(rotMat, self->_up);
    });
}

// rotate around Y axis
- (void)yawAroundCenter:(float)angle {
    dispatch_sync(_syncQueue, ^{
        simd::float4x4 rotMat = AAPL::rotate(angle, self->_up);

        self->_eye = self->_eye - self->_center;
        self->_eye = matrix4_mul_vector3(rotMat, self->_eye);
        self->_eye = self->_eye + self->_center;

        self->_up = matrix4_mul_vector3(rotMat, self->_up);
    });
}

// rotate around X axis
- (void)pitchAroundCenter:(float)angle {
    dispatch_sync(_syncQueue, ^{
        simd::float3 viewDirection = simd_normalize(self->_center - self->_eye);
        simd::float3 rightVector = simd_cross(self->_up, viewDirection);
        
        simd::float4x4 rotMat = AAPL::rotate(angle, rightVector);

        self->_eye = self->_eye - self->_center;
        self->_eye = matrix4_mul_vector3(rotMat, self->_eye);
        self->_eye = self->_eye + self->_center;

        self->_up = matrix4_mul_vector3(rotMat, self->_up);
    });
}

- (void)moveTowardCenter:(float)scale
{
    __block float _scale = scale;
    
    dispatch_sync(_syncQueue, ^{
        simd::float3 direction = self->_center - self->_eye;
        
        // don't move to the other side of _center
        float distance = sqrt(simd_dot(direction, direction));
        if (_scale > distance)
            _scale = distance - 3.0;
        
        direction = simd::normalize(direction);
        direction = direction * _scale;
        self->_eye += direction;
    });
}

-(void)resetView {
    dispatch_sync(_syncQueue, ^{
        self->_center = simd::float3 { 0, 0, 500 };   // start at a distance of ~50cm
        self->_eye = simd::float3 { 0, 0, 0 };
        // The TrueDepth camera outputs frames that are aligned to device landscape, so should be rotated 90 degrees counter-clockwise
        self->_up = simd_float3 { -1 , 0 ,0 };
        
    });
}

-(simd::float4x4)getFinalViewMatrix {
    float aspect = (self.drawableSize.width / self.drawableSize.height);

    // Use a magic number that simply looks good
    float vfov = 70;
    simd::float4x4 appleProjMat = AAPL::perspective_fov(vfov, aspect, 0.01f, 30000);

    __block simd::float3 eye, center, up;
    
    // take camera position in a synchornized way
    dispatch_sync(_syncQueue, ^{
        eye = self->_eye;
        center = self->_center;
        up = self->_up;
    });
                  
    simd::float4x4 appleViewMat = AAPL::lookAt(eye, center, up);
    
    // Final view matrix is projection * view * model. In our case, we never move the model itself, so we can ignore its matrix.
    return appleProjMat * appleViewMat;
}

@end





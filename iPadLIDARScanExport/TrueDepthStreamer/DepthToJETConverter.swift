/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Converts depth values to JET values.
*/

import CoreMedia
import CoreVideo
import Metal

struct BGRAPixel {
    var blue: UInt8 = 0
    var green: UInt8 = 0
    var red: UInt8 = 0
    var alpha: UInt8 = 0
}

struct JETParams {
    var histogramSize: Int32 = 1 << 16
    var binningFactor: Int32 = 8000
}

class ColorTable: NSObject {
    private var tableBuf: MTLBuffer?
    
    required init (metalDevice: MTLDevice, size: Int) {
        self.tableBuf = metalDevice.makeBuffer(length: MemoryLayout<BGRAPixel>.size * size, options: .storageModeShared)
        super.init()
        self.fillJetTable(size: size)
    }
    
    deinit {
    }
    
    // second order curve (from HueWave 2010) -- increases saturation at cyan, magenta, and yellow
    private func wave(_ pos: Double, phase: Double) -> Double {
        let piVal: Double = 4.0 * atan(1.0)
        let sinShift: Double = -1.0 / 4.0
        // Phase shift sine wave such that sin(2pi * (x+sinShift)) == -1
        let xVal: Double = 2.0 * piVal * (pos + sinShift + phase)
        let sVal: Double = (sin(xVal) + 1.0) / 2.0
        // Normalized sin function
        let s2Val: Double = sin(piVal / 2.0 * sVal)
        // Flatten top
        return s2Val * s2Val
        // Symmetrically flattened botton and top
    }
    
    private func fillJetTable(size: Int) {
        let piVal: Double = 4.0 * atan(1.0)
        let rPhase: Double = -1.0 / 4.0
        let gPhase: Double = 0.0
        let bPhase: Double = +1.0 / 4.0
        
        let table = tableBuf?.contents().bindMemory(to: BGRAPixel.self, capacity: size)
        
        table![0].blue = 0
        table![0].green = table![0].blue
        table![0].red = table![0].green
        // Get pixel info
        for idx in 1..<size {
            // Get the normalized position
            let pos = (Double)(idx) / ((Double)(size) - 1.0)
            // Get the current hue value
            var red: Double = wave(pos, phase: rPhase)
            let green: Double = wave(pos, phase: gPhase)
            var blue: Double = wave(pos, phase: bPhase)
            // Preserve the jet color table attenuation of red near the start, and blue near the end
            // Except instead of making them zero, causing a discontinuity, use an 8th order 1-cos function
            if pos < 1.0 / 8.0 {
                // Attenuate red  channel for 0 < x < 1/8
                let xVal: Double = pos * 8.0 * piVal
                var attenuation: Double = (cos(xVal) + 1.0) / 2.0
                attenuation = 1.0 - pow(attenuation, 0.125)
                red *= attenuation
            } else if pos > 7.0 / 8.0 {
                // Attenuate blue channel for 7/8 < x < 1
                let xVal: Double = (1.0 - pos) * 8.0 * piVal
                var attenuation: Double = (cos(xVal) + 1.0) / 2.0
                attenuation = 1.0 - pow(attenuation, 0.125)
                blue *= attenuation
            }
            
            table![idx].alpha = (UInt8)(255)
            table![idx].red = (UInt8)(255 * red)
            table![idx].green = (UInt8)(255 * green)
            table![idx].blue = (UInt8)(255 * blue)
        }
    }
    
    func getColorTable() -> MTLBuffer {
        return tableBuf!
    }
}

class DepthToJETConverter: FilterRenderer {
    
    var description: String = "Depth to JET Converter"
    
    var isPrepared = false
    
    private(set) var inputFormatDescription: CMFormatDescription?
    
    private(set) var outputFormatDescription: CMFormatDescription?
    
    private var inputTextureFormat: MTLPixelFormat = .invalid
    
    private var outputPixelBufferPool: CVPixelBufferPool!
    
    private let metalDevice = MTLCreateSystemDefaultDevice()!
    
    private let jetParams = JETParams()
    
    private let colors = 512
    
    private let jetParamsBuffer: MTLBuffer
    
    private let histogramBuffer: MTLBuffer
    
    private var computePipelineState: MTLComputePipelineState?
    
    private lazy var commandQueue: MTLCommandQueue? = {
        return self.metalDevice.makeCommandQueue()
    }()
    
    private var textureCache: CVMetalTextureCache!
    
    private var lowest: Float = 0.0
    
    private var highest: Float = 0.0
    
    private var colorBuf: MTLBuffer?
    
    required init() {
        let defaultLibrary = metalDevice.makeDefaultLibrary()!
        let kernelFunction = defaultLibrary.makeFunction(name: "depthToJET")
        do {
            computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        } catch {
            fatalError("Unable to create depth converter pipeline state. (\(error))")
        }
        
        guard let histBuffer = metalDevice.makeBuffer(
            length: MemoryLayout<Float>.size * Int(jetParams.histogramSize),
            options: .storageModeShared) else {
                fatalError("Failed to allocate buffer for histogram")
        }
        
        self.histogramBuffer = histBuffer
        
        guard let jetBuffer = metalDevice.makeBuffer(length: MemoryLayout<JETParams>.size, options: .storageModeShared) else {
            fatalError("Failed to allocate buffer for histogram size")
        }
        
        jetBuffer.contents().bindMemory(to: JETParams.self, capacity: 1)
            .assign(repeating: self.jetParams, count: 1)
        
        self.jetParamsBuffer = jetBuffer
    }
    
    static private func allocateOutputBufferPool(with formatDescription: CMFormatDescription,
                                                 outputRetainedBufferCountHint: Int) -> CVPixelBufferPool? {
        let inputDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let outputBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
            kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
        var cvPixelBufferPool: CVPixelBufferPool?
        // Create a pixel buffer pool with the same pixel attributes as the input format description
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, outputBufferAttributes as NSDictionary?, &cvPixelBufferPool)
        guard let pixelBufferPool = cvPixelBufferPool else {
            assertionFailure("Allocation failure: Could not create pixel buffer pool")
            return nil
        }
        return pixelBufferPool
    }
    
    func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        reset()
        
        outputPixelBufferPool = DepthToJETConverter.allocateOutputBufferPool(with: formatDescription,
                                                                             outputRetainedBufferCountHint: outputRetainedBufferCountHint)
        if outputPixelBufferPool == nil {
            return
        }
        
        var pixelBuffer: CVPixelBuffer?
        var pixelBufferFormatDescription: CMFormatDescription?
        _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &pixelBuffer)
        if pixelBuffer != nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer!,
                                                         formatDescriptionOut: &pixelBufferFormatDescription)
        }
        pixelBuffer = nil
        
        inputFormatDescription = formatDescription
        outputFormatDescription = pixelBufferFormatDescription
        
        let inputMediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        if inputMediaSubType == kCVPixelFormatType_DepthFloat16 {
            inputTextureFormat = .r16Float
        } else {
            assertionFailure("Input format not supported")
        }
        
        var metalTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
            assertionFailure("Unable to allocate depth converter texture cache")
        } else {
            textureCache = metalTextureCache
        }
        
        let colorTable = ColorTable(metalDevice: metalDevice, size: self.colors)
        colorBuf = colorTable.getColorTable()
        
        isPrepared = true
    }
    
    func reset() {
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        textureCache = nil
        isPrepared = false
    }
    
    // MARK: - Depth to JET Conversion
    
    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if !isPrepared {
            assertionFailure("Invalid state: Not prepared")
            return nil
        }
        
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
        guard let outputPixelBuffer = newPixelBuffer else {
            print("Allocation failure: Could not get pixel buffer from pool (\(self.description))")
            return nil
        }
        
        let hist = histogramBuffer.contents().bindMemory(to: Float.self, capacity: Int(self.jetParams.histogramSize))
        
        HistogramCalculator.calcHistogram(for: pixelBuffer,
                                          toBuffer: hist,
                                          withSize: self.jetParams.histogramSize,
                                          forColors: Int32(colors),
                                          minDepth: 0.0,
                                          maxDepth: 1.0,
                                          binningFactor: self.jetParams.binningFactor)
        
        var min: Float = 0.0
        var max: Float = 0.0
        minMaxFromPixelBuffer(pixelBuffer, &min, &max, inputTextureFormat)
        if min < lowest {
            lowest = min
        }
        
        if max > highest{
            highest = max
        }
        
        guard let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm),
            let inputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer, textureFormat: inputTextureFormat) else {
                return nil
        }
        
        // Set up command queue, buffer, and encoder
        guard let commandQueue = commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
                print("Failed to create Metal command queue")
                CVMetalTextureCacheFlush(textureCache!, 0)
                return nil
        }
        
        commandEncoder.label = "Depth to JET"
        commandEncoder.setComputePipelineState(computePipelineState!)
        commandEncoder.setTexture(inputTexture, index: 0)
        commandEncoder.setTexture(outputTexture, index: 1)
        commandEncoder.setBuffer(self.jetParamsBuffer, offset: 0, index: 0)
        commandEncoder.setBuffer(self.histogramBuffer, offset: 0, index: 1)
        commandEncoder.setBuffer(colorBuf, offset: 0, index: 2)
        
        // Set up thread groups as described in https://developer.apple.com/reference/metal/mtlcomputecommandencoder
        let width = computePipelineState!.threadExecutionWidth
        let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
        let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
        let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
                                          height: (inputTexture.height + height - 1) / height,
                                          depth: 1)
        commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        
        commandEncoder.endEncoding()
        
        commandBuffer.commit()
        
        return outputPixelBuffer
    }
    
    func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create a Metal texture from the image buffer
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("Depth converter failed to create preview texture")
            CVMetalTextureCacheFlush(textureCache, 0)
            return nil
        }
        
        return texture
    }
}

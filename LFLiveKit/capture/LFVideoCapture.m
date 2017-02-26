//
//  LFVideoCapture.m
//  LFLiveKit
//
//  Created by 倾慕 on 16/5/1.
//  Copyright © 2016年 倾慕. All rights reserved.
//

#import "LFVideoCapture.h"
#import "LFGPUImageBeautyFilter.h"
#import "LFGPUImageEmptyFilter.h"

#if __has_include(<GPUImage/GPUImage.h>)
#import <GPUImage/GPUImage.h>
#elif __has_include("GPUImage/GPUImage.h")
#import "GPUImage/GPUImage.h"
#else
#import "GPUImage.h"
#endif

@interface LFVideoCapture ()

@property (nonatomic, strong) LFLiveVideoConfiguration *configuration;
@property (nonatomic, strong) GPUImageVideoCamera *videoCamera;
@property (nonatomic, strong) GPUImageCropFilter *cropfilter;
@property (nonatomic, strong) GPUImageOutput<GPUImageInput> *output;
@property (nonatomic, strong) GPUImageView *gpuImageView;
@property (nonatomic, strong) GPUImageMovieWriter *movieWriter;

@end

@implementation LFVideoCapture
@synthesize filter = _filter;
@synthesize torch = _torch;
@synthesize zoomScale = _zoomScale;

#pragma mark -- Lifecycle

- (instancetype)initWithVideoConfiguration:(LFLiveVideoConfiguration *)configuration {
    if (self = [super init]) {
        _configuration = configuration;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterBackground:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusBarChanged:) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
        
        self.zoomScale = 1.0;
    }
    return self;
}

- (void)dealloc {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_videoCamera stopCameraCapture];
    if(_gpuImageView){
        [_gpuImageView removeFromSuperview];
        _gpuImageView = nil;
    }
}

#pragma mark -- Setter Getter

- (GPUImageVideoCamera *)videoCamera{
    if(!_videoCamera){
        _videoCamera = [[GPUImageVideoCamera alloc] initWithSessionPreset:_configuration.avSessionPreset cameraPosition:AVCaptureDevicePositionFront];
        _videoCamera.outputImageOrientation = _configuration.outputImageOrientation;
        _videoCamera.horizontallyMirrorFrontFacingCamera = YES;
        _videoCamera.horizontallyMirrorRearFacingCamera = NO;
        _videoCamera.frameRate = (int32_t)_configuration.videoFrameRate;
        
        [_videoCamera addTarget:self.filter];
    }
    return _videoCamera;
}

- (void)setRunning:(BOOL)running {
    if (_running == running) return;
    _running = running;
    
    if (!_running) {
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [self.videoCamera stopCameraCapture];
        if(self.saveLocalVideo) [self.movieWriter finishRecording];
    } else {
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        [self.videoCamera startCameraCapture];
        if(self.saveLocalVideo) [self.movieWriter startRecording];
    }
}

- (void)setPreView:(UIView *)preView {
    if (self.gpuImageView.superview) [self.gpuImageView removeFromSuperview];
    [preView insertSubview:self.gpuImageView atIndex:0];
    self.gpuImageView.frame = CGRectMake(0, 0, preView.frame.size.width, preView.frame.size.height);
}

- (UIView *)preView {
    return self.gpuImageView.superview;
}

- (void)setCaptureDevicePosition:(AVCaptureDevicePosition)captureDevicePosition {
    [self.videoCamera rotateCamera];
    self.videoCamera.frameRate = (int32_t)_configuration.videoFrameRate;
}

- (AVCaptureDevicePosition)captureDevicePosition {
    return [self.videoCamera cameraPosition];
}

- (void)setVideoFrameRate:(NSInteger)videoFrameRate {
    if (videoFrameRate <= 0) return;
    if (videoFrameRate == self.videoCamera.frameRate) return;
    self.videoCamera.frameRate = (uint32_t)videoFrameRate;
}

- (NSInteger)videoFrameRate {
    return self.videoCamera.frameRate;
}

- (void)setTorch:(BOOL)torch {
    BOOL ret = torch;
    if (!self.videoCamera.captureSession) return;
    AVCaptureSession *session = (AVCaptureSession *)self.videoCamera.captureSession;
    [session beginConfiguration];
    if (self.videoCamera.inputCamera) {
        if (self.videoCamera.inputCamera.torchAvailable) {
            NSError *err = nil;
            if ([self.videoCamera.inputCamera lockForConfiguration:&err]) {
                [self.videoCamera.inputCamera setTorchMode:(torch ? AVCaptureTorchModeOn : AVCaptureTorchModeOff) ];
                [self.videoCamera.inputCamera unlockForConfiguration];
                ret = (self.videoCamera.inputCamera.torchMode == AVCaptureTorchModeOn);
            } else {
                NSLog(@"Error while locking device for torch: %@", err);
                ret = false;
            }
        } else {
            NSLog(@"Torch not available in current camera input");
        }
    }
    [session commitConfiguration];
    _torch = ret;
}

- (BOOL)torch {
    return self.videoCamera.inputCamera.torchMode;
}

- (void)setMirror:(BOOL)mirror {
    self.videoCamera.horizontallyMirrorFrontFacingCamera = mirror;
}

- (BOOL)mirror {
    return self.videoCamera.horizontallyMirrorFrontFacingCamera;
}

- (void)setZoomScale:(CGFloat)zoomScale {
    if (self.videoCamera && self.videoCamera.inputCamera) {
        AVCaptureDevice *device = (AVCaptureDevice *)self.videoCamera.inputCamera;
        if ([device lockForConfiguration:nil]) {
            device.videoZoomFactor = zoomScale;
            [device unlockForConfiguration];
            _zoomScale = zoomScale;
        }
    }
}

- (CGFloat)zoomScale {
    return _zoomScale;
}

- (GPUImageView *)gpuImageView{
    if(!_gpuImageView){
        _gpuImageView = [[GPUImageView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        [_gpuImageView setFillMode:kGPUImageFillModePreserveAspectRatioAndFill];
        [_gpuImageView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    }
    return _gpuImageView;
}

-(UIImage *)currentImage{
    if(_output){
        [_output useNextFrameForImageCapture];
        return _output.imageFromCurrentFramebuffer;
    }
    return nil;
}

- (GPUImageMovieWriter*)movieWriter{
    if(!_movieWriter){
        _movieWriter = [[GPUImageMovieWriter alloc] initWithMovieURL:self.saveLocalVideoPath size:self.configuration.videoSize];
        _movieWriter.encodingLiveVideo = YES;
        _movieWriter.shouldPassthroughAudio = YES;
        self.videoCamera.audioEncodingTarget = self.movieWriter;
    }
    return _movieWriter;
}

- (GPUImageOutput<GPUImageInput> *)filter {
    if (!_filter) {
        _filter = [[LFGPUImageEmptyFilter alloc] init];
        [_filter forceProcessingAtSize:self.configuration.videoSize];
        [_filter addTarget:self.output];
    }
    return _filter;
}

- (void)setFilter:(GPUImageOutput<GPUImageInput> *)filter {
    if (_filter) {
        [self.videoCamera removeTarget:_filter];
        [_filter removeAllTargets];
    }
    _filter = filter;
    [self.videoCamera addTarget:_filter];
    [_filter addTarget:self.output];
}

- (void)addView:(UIView *)view {
    [self addView:view withFilter:nil];
}

- (void)addView:(UIView *)view withFilter:(GPUImageOutput<GPUImageInput> *)filter {
    if (!filter) {
        filter = [[LFGPUImageEmptyFilter alloc] init];
    }
    GPUImageView *gpuImageView = [[GPUImageView alloc] initWithFrame:view.bounds];
    gpuImageView.fillMode = kGPUImageFillModePreserveAspectRatioAndFill;
    gpuImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    [filter forceProcessingAtSize:gpuImageView.sizeInPixels];
    [filter addTarget:gpuImageView];
    [view addSubview:gpuImageView];
    
    [self.videoCamera addTarget:filter];
}

- (GPUImageOutput<GPUImageInput> *)output {
    if (!_output) {
        _output = [[LFGPUImageEmptyFilter alloc] init];
        [_output forceProcessingAtSize:self.configuration.videoSize];
        [_output addTarget:self.gpuImageView];
        
        if(self.saveLocalVideo){
            [_output addTarget:self.movieWriter];
        }
        
        __weak typeof(self) _self = self;
        [_output setFrameProcessingCompletionBlock:^(GPUImageOutput *output, CMTime time) {
            [_self processVideo:output];
        }];
    }
    return _output;
}

#pragma mark -- Custom Method

- (void)processVideo:(GPUImageOutput *)output {
    __weak typeof(self) _self = self;
    @autoreleasepool {
        GPUImageFramebuffer *imageFramebuffer = output.framebufferForOutput;
        CVPixelBufferRef pixelBuffer = [imageFramebuffer pixelBuffer];
        if (pixelBuffer && _self.delegate && [_self.delegate respondsToSelector:@selector(captureOutput:pixelBuffer:)]) {
            [_self.delegate captureOutput:_self pixelBuffer:pixelBuffer];
        }
    }
}

#pragma mark Notification

- (void)willEnterBackground:(NSNotification *)notification {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self.videoCamera pauseCameraCapture];
    runSynchronouslyOnVideoProcessingQueue(^{
        glFinish();
    });
}

- (void)willEnterForeground:(NSNotification *)notification {
    [self.videoCamera resumeCameraCapture];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

- (void)statusBarChanged:(NSNotification *)notification {
    UIInterfaceOrientation statusBar = [[UIApplication sharedApplication] statusBarOrientation];

    if(self.configuration.autorotate){
        self.videoCamera.outputImageOrientation = statusBar;
    }
}

@end

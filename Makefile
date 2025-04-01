ARCHS = arm64
TARGET := iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CameraPreviewTweak

CameraPreviewTweak_FILES = Tweak.xm FloatingWindow.m WebRTCManager.m WebRTCFrameConverter.m WebRTCBufferInjector.m logger.m PixelBufferLocker.m
CameraPreviewTweak_FRAMEWORKS = UIKit AVFoundation QuartzCore CoreImage CoreVideo CoreAudio AudioToolbox
CameraPreviewTweak_LIBRARIES = substrate
CameraPreviewTweak_CFLAGS = -fobjc-arc -F./Pods/GoogleWebRTC/Frameworks/frameworks -I./Pods/GoogleWebRTC/Frameworks/frameworks/WebRTC.framework/Headers
CameraPreviewTweak_LDFLAGS = -F./Pods/GoogleWebRTC/Frameworks/frameworks -framework WebRTC -Xlinker -rpath -Xlinker /Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework
	cp -R ./Pods/GoogleWebRTC/Frameworks/frameworks/WebRTC.framework/* $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework/

after-install::
	install.exec "mkdir -p /Library/Frameworks/WebRTC.framework"
	install.exec "cp -R ./Pods/GoogleWebRTC/Frameworks/frameworks/WebRTC.framework/* /Library/Frameworks/WebRTC.framework/"
	install.exec "ldid -S /Library/Frameworks/WebRTC.framework/WebRTC"

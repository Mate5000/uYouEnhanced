ARCHS = arm64
TARGET := iphone:clang:16.5:13.0
YTAEQ_EMBEDDED ?= 0
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTAudioEQ
YTAudioEQ_FILES = Tweak.xm AudioHooks.mm AudioDSP.cpp Settings.mm Vendor/fishhook.c
ifeq ($(YTAEQ_EMBEDDED),0)
YTAudioEQ_FILES += StandaloneSettings.xm
endif
YTAudioEQ_FRAMEWORKS = UIKit Foundation AVFoundation AudioToolbox CoreMedia
YTAudioEQ_CFLAGS = -Wall -Wextra -DYTAEQ_EMBEDDED=$(YTAEQ_EMBEDDED) -Drebind_symbols=YTAEQRebindSymbols -Drebind_symbols_image=YTAEQRebindSymbolsImage
YTAudioEQ_OBJCFLAGS = -fobjc-arc -fobjc-exceptions
YTAudioEQ_CCFLAGS = -std=c++17 -fexceptions -fcxx-exceptions

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support"
	@cp -R Resources/YTAudioEQ.bundle "$(THEOS_STAGING_DIR)/Library/Application Support/"

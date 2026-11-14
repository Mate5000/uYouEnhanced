#pragma once
#import <UIKit/UIKit.h>
#include "AudioDSP.hpp"

NSString *YTAEQLocalize(NSString *key);
void YTAEQInitializeSettings();
ytaeq::Configuration YTAEQCurrentConfiguration();
void YTAEQSaveConfiguration(ytaeq::Configuration configuration);
void YTAEQPresentPanel(id responder, UIView *sourceView);
UIViewController *YTAEQCreatePanel();

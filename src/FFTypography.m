#import "FFTypography.h"

UIFont *FFPreferredFont(UIFontTextStyle style, UIFontWeight weight)
{
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    UIFont *base = [UIFont systemFontOfSize:descriptor.pointSize weight:weight];
    UIFontMetrics *metrics = [UIFontMetrics metricsForTextStyle:style];
    return [metrics scaledFontForFont:base];
}

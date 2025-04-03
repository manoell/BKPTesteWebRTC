#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()

@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UILabel *dimensionsLabel;
@property (nonatomic, strong) UIView *topBarView;
@property (nonatomic, strong) UIView *buttonContainer;
@property (nonatomic, strong) CAGradientLayer *topGradient;
@property (nonatomic, strong) CAGradientLayer *bottomGradient;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, assign) CGRect expandedFrame;
@property (nonatomic, assign) CGRect minimizedFrame;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, strong) UIView *formatInfoContainer;
@property (nonatomic, strong) UILabel *processingModeLabel;
@property (nonatomic, strong) NSTimer *periodicUpdateTimer;
@property (nonatomic, strong) NSString *currentPixelFormat;
@property (nonatomic, strong) NSString *currentProcessingMode;

@end

@implementation FloatingWindow

#pragma mark - Initialization & Setup
- (instancetype)init {
    if (@available(iOS 13.0, *)) {
        UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self = [super initWithWindowScene:(UIWindowScene *)scene];
        } else {
            self = [super init];
        }
    } else {
        self = [super init];
    }
    
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
        self.layer.cornerRadius = 25;
        self.clipsToBounds = YES;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat margin = 20.0;
        CGFloat expandedWidth = screenBounds.size.width - (2 * margin);
        CGFloat expandedHeight = screenBounds.size.height - (2 * margin) - 20;
        self.expandedFrame = CGRectMake(
            margin,
            margin + 10,
            expandedWidth,
            expandedHeight
        );
        CGFloat minimizedSize = 50;
        self.minimizedFrame = CGRectMake(
            screenBounds.size.width - minimizedSize - 20,
            screenBounds.size.height * 0.4,
            minimizedSize,
            minimizedSize
        );
        self.frame = self.minimizedFrame;
        self.windowState = FloatingWindowStateMinimized;
        self.lastFrameSize = CGSizeZero;
        self.isPreviewActive = NO;
        self.isReceivingFrames = NO;
        self.currentFps = 0;
        self.currentPixelFormat = @"Desconhecido";
        self.currentProcessingMode = @"Aguardando";
        [self setupUI];
        [self setupGestureRecognizers];
        [self updateAppearanceForState:self.windowState];
        writeLog(@"[FloatingWindow] Janela flutuante inicializada em modo minimizado");
    }
    return self;
}

- (void)setupUI {
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentView];
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [self setupVideoView];
    [self setupTopBar];
    [self setupFormatInfoSection];
    [self setupBottomControls];
    [self setupLoadingIndicator];
    [self setupGradients];
    [self setupMinimizedIcon];
}

- (void)setupVideoView {
    self.videoView = [[RTCMTLVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
}

- (void)setupTopBar {
    self.topBarView = [[UIView alloc] init];
    self.topBarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.topBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.topBarView];
    [NSLayoutConstraint activateConstraints:@[
        [self.topBarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.topBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.topBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.topBarView.heightAnchor constraintEqualToConstant:60],
    ]];
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"WebRTC Preview";
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.topBarView addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.topBarView.topAnchor constant:8],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.topBarView.centerXAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.topBarView.widthAnchor constant:-20],
    ]];
    self.dimensionsLabel = [[UILabel alloc] init];
    self.dimensionsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.dimensionsLabel.text = @"";
    self.dimensionsLabel.textColor = [UIColor whiteColor];
    self.dimensionsLabel.textAlignment = NSTextAlignmentCenter;
    self.dimensionsLabel.backgroundColor = [UIColor clearColor];
    self.dimensionsLabel.font = [UIFont systemFontOfSize:12];
    [self.topBarView addSubview:self.dimensionsLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.dimensionsLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:4],
        [self.dimensionsLabel.centerXAnchor constraintEqualToAnchor:self.topBarView.centerXAnchor],
        [self.dimensionsLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.topBarView.widthAnchor constant:-20],
    ]];
}

- (void)setupFormatInfoSection {
    self.formatInfoContainer = [[UIView alloc] init];
    self.formatInfoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.formatInfoContainer.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.2 alpha:0.7];
    self.formatInfoContainer.layer.cornerRadius = 8;
    [self.contentView addSubview:self.formatInfoContainer];
    [NSLayoutConstraint activateConstraints:@[
        [self.formatInfoContainer.topAnchor constraintEqualToAnchor:self.topBarView.bottomAnchor constant:8],
        [self.formatInfoContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [self.formatInfoContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [self.formatInfoContainer.heightAnchor constraintEqualToConstant:40] // Altura para acomodar duas linhas de texto
    ]];
    self.formatInfoLabel = [[UILabel alloc] init];
    self.formatInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.formatInfoLabel.text = @"Formato: Aguardando stream...";
    self.formatInfoLabel.textColor = [UIColor whiteColor];
    self.formatInfoLabel.textAlignment = NSTextAlignmentCenter;
    self.formatInfoLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [self.formatInfoContainer addSubview:self.formatInfoLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.formatInfoLabel.topAnchor constraintEqualToAnchor:self.formatInfoContainer.topAnchor constant:5],
        [self.formatInfoLabel.leadingAnchor constraintEqualToAnchor:self.formatInfoContainer.leadingAnchor constant:8],
        [self.formatInfoLabel.trailingAnchor constraintEqualToAnchor:self.formatInfoContainer.trailingAnchor constant:-8],
    ]];
    self.processingModeLabel = [[UILabel alloc] init];
    self.processingModeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.processingModeLabel.text = @"Processamento: Aguardando dados...";
    self.processingModeLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    self.processingModeLabel.textAlignment = NSTextAlignmentCenter;
    self.processingModeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    [self.formatInfoContainer addSubview:self.processingModeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.processingModeLabel.topAnchor constraintEqualToAnchor:self.formatInfoLabel.bottomAnchor constant:2],
        [self.processingModeLabel.leadingAnchor constraintEqualToAnchor:self.formatInfoContainer.leadingAnchor constant:8],
        [self.processingModeLabel.trailingAnchor constraintEqualToAnchor:self.formatInfoContainer.trailingAnchor constant:-8],
    ]];
    self.formatInfoContainer.alpha = 0;
}

- (void)setupBottomControls {
    self.buttonContainer = [[UIView alloc] init];
    self.buttonContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.buttonContainer.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.buttonContainer];
    [NSLayoutConstraint activateConstraints:@[
        [self.buttonContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
        [self.buttonContainer.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.buttonContainer.widthAnchor constraintEqualToConstant:180],
        [self.buttonContainer.heightAnchor constraintEqualToConstant:50],
    ]];
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor]; // Verde inicialmente
    self.toggleButton.layer.cornerRadius = 10;
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttonContainer addSubview:self.toggleButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.leadingAnchor constraintEqualToAnchor:self.buttonContainer.leadingAnchor],
        [self.toggleButton.trailingAnchor constraintEqualToAnchor:self.buttonContainer.trailingAnchor],
        [self.toggleButton.topAnchor constraintEqualToAnchor:self.buttonContainer.topAnchor],
        [self.toggleButton.bottomAnchor constraintEqualToAnchor:self.buttonContainer.bottomAnchor],
    ]];
}

- (void)setupLoadingIndicator {
    if (@available(iOS 13.0, *)) {
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.loadingIndicator.color = [UIColor whiteColor];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        #pragma clang diagnostic pop
    }
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:self.loadingIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

- (void)setupMinimizedIcon {
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor whiteColor];
    [self addSubview:self.iconView];
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26]
    ]];
    [self updateMinimizedIconWithState];
    self.iconView.hidden = YES;
}

- (void)setupGradients {
    self.topGradient = [CAGradientLayer layer];
    self.topGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0.8] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor]
    ];
    self.topGradient.locations = @[@0.0, @1.0];
    self.topGradient.startPoint = CGPointMake(0.5, 0.0);
    self.topGradient.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer insertSublayer:self.topGradient atIndex:0];
    self.bottomGradient = [CAGradientLayer layer];
    self.bottomGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0.8] CGColor]
    ];
    self.bottomGradient.locations = @[@0.0, @1.0];
    self.bottomGradient.startPoint = CGPointMake(0.5, 0.0);
    self.bottomGradient.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer insertSublayer:self.bottomGradient atIndex:0];
}

- (void)setupGestureRecognizers {
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    panGesture.maximumNumberOfTouches = 1;
    panGesture.minimumNumberOfTouches = 1;
    [self addGestureRecognizer:panGesture];
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    [tapGesture requireGestureRecognizerToFail:panGesture];
}

#pragma mark - Layout
- (void)layoutSubviews {
    [super layoutSubviews];
    self.topGradient.frame = CGRectMake(0, 0, self.bounds.size.width, 60);
    self.bottomGradient.frame = CGRectMake(0, self.bounds.size.height - 80, self.bounds.size.width, 80);
}

#pragma mark - Public Methods
- (void)show {
    self.frame = self.minimizedFrame;
    self.windowState = FloatingWindowStateMinimized;
    [self updateAppearanceForState:self.windowState];
    self.hidden = NO;
    self.alpha = 0;
    self.transform = CGAffineTransformMakeScale(0.5, 0.5);
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 0.8;
    } completion:nil];
    [self makeKeyAndVisible];
    writeLog(@"[FloatingWindow] Janela flutuante mostrada");
}

- (void)hide {
    [self stopPreview];
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.5, 0.5);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    writeLog(@"[FloatingWindow] Janela flutuante ocultada");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        [self startPreview];
    }
}

- (void)startPreview {
    if (!self.webRTCManager) {
        writeLog(@"[FloatingWindow] WebRTCManager não inicializado");
        [self updateConnectionStatus:@"Erro: gerenciador não inicializado"];
        return;
    }
    if (self.isPreviewActive) {
        writeLog(@"[FloatingWindow] Preview já está ativo, ignorando solicitação duplicada");
        return;
    }
    self.isReceivingFrames = NO;
    self.lastFrameSize = CGSizeZero;
    self.currentFps = 0;
    self.isPreviewActive = YES;
    [self.toggleButton setTitle:@"Desativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor redColor];
    [self.loadingIndicator startAnimating];
    [self updateConnectionStatus:@"Conectando..."];
    @try {
        [self.webRTCManager startWebRTC];
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exceção ao iniciar WebRTC: %@", exception);
        self.isPreviewActive = NO;
        [self.loadingIndicator stopAnimating];
        [self updateConnectionStatus:@"Erro ao iniciar conexão"];
        [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
        return;
    }
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    }
    [self startPeriodicUpdates];
    [self updateMinimizedIconWithState];
}

- (void)stopPreview {
    if (!self.isPreviewActive) return;
    writeLog(@"[FloatingWindow] Parando preview");
    self.isPreviewActive = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor];
    [self stopPeriodicUpdates];
    [self.loadingIndicator stopAnimating];
    [self updateConnectionStatus:@"Desconectado"];
    self.dimensionsLabel.text = @"";
    [UIView animateWithDuration:0.3 animations:^{
        self.formatInfoContainer.alpha = 0;
    }];
    self.isReceivingFrames = NO;
    if (self.webRTCManager) {
        @try {
            [self.webRTCManager sendByeMessage];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.webRTCManager stopWebRTC:YES];
            });
        } @catch (NSException *exception) {
            writeLog(@"[FloatingWindow] Exceção ao desativar WebRTC: %@", exception);
            [self.webRTCManager stopWebRTC:YES];
        }
    }
    [self updateMinimizedIconWithState];
}

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
        [self updateMinimizedIconWithState];
    });
}

#pragma mark - Format Information Methods
- (void)updateFormatInfo:(NSString *)formatInfo {
    if (!formatInfo) {
        return;
    }
    self.currentPixelFormat = formatInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.formatInfoContainer.alpha < 1.0) {
            [UIView animateWithDuration:0.3 animations:^{
                self.formatInfoContainer.alpha = 1.0;
            }];
        }
        self.formatInfoLabel.text = [NSString stringWithFormat:@"Formato: %@", formatInfo];
        if ([formatInfo containsString:@"420f"]) {
            self.formatInfoLabel.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0];
        } else if ([formatInfo containsString:@"420v"]) {
            self.formatInfoLabel.textColor = [UIColor colorWithRed:0.9 green:0.9 blue:0.2 alpha:1.0];
        } else if ([formatInfo containsString:@"BGRA"]) {
            self.formatInfoLabel.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
        } else {
            self.formatInfoLabel.textColor = [UIColor whiteColor];
        }
    });
}

- (void)updateProcessingMode:(NSString *)processingMode {
    if (!processingMode) {
        return;
    }
    self.currentProcessingMode = processingMode;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.processingModeLabel.text = [NSString stringWithFormat:@"Processamento: %@", processingMode];
        if ([processingMode containsString:@"hardware"]) {
            self.processingModeLabel.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0];
        } else if ([processingMode containsString:@"software"]) {
            self.processingModeLabel.textColor = [UIColor colorWithRed:0.9 green:0.9 blue:0.2 alpha:1.0];
        } else {
            self.processingModeLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
        }
    });
}

- (void)updateIconWithFormatInfo {
    UIImageView *formatBadge = (UIImageView *)[self viewWithTag:1001];
    if (self.windowState == FloatingWindowStateMinimized && self.isPreviewActive && self.isReceivingFrames) {
        if (!formatBadge) {
            formatBadge = [[UIImageView alloc] init];
            formatBadge.translatesAutoresizingMaskIntoConstraints = NO;
            formatBadge.tag = 1001;
            formatBadge.layer.cornerRadius = 6;
            formatBadge.clipsToBounds = YES;
            formatBadge.layer.borderWidth = 1.0;
            formatBadge.layer.borderColor = [UIColor whiteColor].CGColor;
            [self addSubview:formatBadge];
            [NSLayoutConstraint activateConstraints:@[
                [formatBadge.widthAnchor constraintEqualToConstant:12],
                [formatBadge.heightAnchor constraintEqualToConstant:12],
                [formatBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
                [formatBadge.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6]
            ]];
        }
        if ([self.currentPixelFormat containsString:@"420f"]) {
            formatBadge.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0];
        } else if ([self.currentPixelFormat containsString:@"420v"]) {
            formatBadge.backgroundColor = [UIColor colorWithRed:0.8 green:0.8 blue:0.0 alpha:1.0];
        } else if ([self.currentPixelFormat containsString:@"BGRA"]) {
            formatBadge.backgroundColor = [UIColor colorWithRed:0.0 green:0.3 blue:0.8 alpha:1.0];
        } else {
            formatBadge.backgroundColor = [UIColor lightGrayColor];
        }
        formatBadge.hidden = NO;
    } else {
        if (formatBadge) {
            formatBadge.hidden = YES;
        }
    }
    [self updateMinimizedIconWithState];
}

#pragma mark - State Management
- (void)setWindowState:(FloatingWindowState)windowState {
    if (_windowState == windowState) return;
    _windowState = windowState;
    [self updateAppearanceForState:windowState];
    if (windowState == FloatingWindowStateExpanded && self.isPreviewActive) {
        [self startPeriodicUpdates];
    } else {
        [self stopPeriodicUpdates];
    }
}

- (void)updateAppearanceForState:(FloatingWindowState)state {
    switch (state) {
        case FloatingWindowStateMinimized:
            [self animateToMinimizedState];
            break;
        case FloatingWindowStateExpanded:
            [self animateToExpandedState];
            break;
    }
}

- (void)animateToMinimizedState {
    [self updateMinimizedIconWithState];
    self.iconView.hidden = NO;
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.frame = self.minimizedFrame;
        self.layer.cornerRadius = self.frame.size.width / 2;
        self.alpha = 0.8;
        self.topBarView.alpha = 0;
        self.buttonContainer.alpha = 0;
        self.videoView.alpha = 0;
        self.formatInfoContainer.alpha = 0;
        [self updateBackgroundColorForState];
    } completion:^(BOOL finished) {
        self.topBarView.hidden = YES;
        self.buttonContainer.hidden = YES;
        self.videoView.hidden = YES;
        self.formatInfoContainer.hidden = YES;
    }];
}

- (void)animateToExpandedState {
    self.topBarView.hidden = NO;
    self.buttonContainer.hidden = NO;
    self.videoView.hidden = NO;
    self.formatInfoContainer.hidden = NO;
    self.iconView.hidden = YES;
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.frame = self.expandedFrame;
        self.layer.cornerRadius = 12;
        self.alpha = 1.0;
        self.topBarView.alpha = 1.0;
        self.buttonContainer.alpha = 1.0;
        self.videoView.alpha = 1.0;
        if (self.isPreviewActive && self.isReceivingFrames) {
            self.formatInfoContainer.alpha = 1.0;
        }
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
    } completion:nil];
}

- (void)updateBackgroundColorForState {
    if (self.windowState != FloatingWindowStateMinimized) return;
    if (self.isPreviewActive) {
        if (self.isReceivingFrames) {
            self.backgroundColor = [UIColor colorWithRed:0.0 green:0.7 blue:0.0 alpha:0.9];
        } else {
            self.backgroundColor = [UIColor colorWithRed:0.7 green:0.7 blue:0.0 alpha:0.9];
        }
    } else {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
    }
}

- (void)updateMinimizedIconWithState {
    UIImage *image = nil;
    if (@available(iOS 13.0, *)) {
        if (self.isPreviewActive) {
            image = [UIImage systemImageNamed:@"video.fill"];
            self.iconView.tintColor = [UIColor greenColor];
        } else {
            image = [UIImage systemImageNamed:@"video.slash"];
            self.iconView.tintColor = [UIColor redColor];
        }
    }
    if (!image) {
        CGSize iconSize = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(iconSize, NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) {
            CGContextSetFillColorWithColor(context,
                self.isPreviewActive ? [UIColor greenColor].CGColor : [UIColor redColor].CGColor);
            CGContextFillEllipseInRect(context, CGRectMake(0, 0, iconSize.width, iconSize.height));
            image = UIGraphicsGetImageFromCurrentImageContext();
        }
        UIGraphicsEndImageContext();
    }
    self.iconView.image = image;
    [self updateBackgroundColorForState];
}

#pragma mark - Gesture Handlers
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (self.windowState == FloatingWindowStateMinimized) {
            [self snapToEdgeIfNeeded];
        }
    }
}

- (void)snapToEdgeIfNeeded {
    if (self.windowState != FloatingWindowStateMinimized) return;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat padding = 10;
    if (center.x < screenBounds.size.width / 2) {
        center.x = self.frame.size.width / 2 + padding;
    } else {
        center.x = screenBounds.size.width - self.frame.size.width / 2 - padding;
    }
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.center = center;
    } completion:^(BOOL finished) {
        self.minimizedFrame = self.frame;
    }];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.isDragging) {
        return;
    }
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    } else {
        CGPoint location = [gesture locationInView:self];
        BOOL tappedOnButton = NO;
        if (self.buttonContainer) {
            CGPoint pointInButtonContainer = [self.buttonContainer convertPoint:location fromView:self];
            if ([self.buttonContainer pointInside:pointInButtonContainer withEvent:nil]) {
                tappedOnButton = YES;
            }
        }
        if (!tappedOnButton) {
            [self setWindowState:FloatingWindowStateMinimized];
        }
    }
}

#pragma mark - RTCVideoViewDelegate
- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    self.lastFrameSize = size;
    if (size.width > 0 && size.height > 0) {
        self.isReceivingFrames = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            float fps = self.currentFps > 0 ? self.currentFps : (self.webRTCManager ? [self.webRTCManager getEstimatedFps] : 0);
            self.currentFps = fps;
            NSString *infoText;
            if (fps > 0) {
                infoText = [NSString stringWithFormat:@"%dx%d @ %.0ffps",
                           (int)size.width, (int)size.height, fps];
            } else {
                infoText = [NSString stringWithFormat:@"%dx%d",
                           (int)size.width, (int)size.height];
            }
            [self updateConnectionStatus:@"Recebendo stream"];
            UILabel *dimensionsLabel = [self valueForKey:@"dimensionsLabel"];
            if (dimensionsLabel) {
                dimensionsLabel.text = infoText;
            }
            if (self.webRTCManager && self.webRTCManager.frameConverter) {
                IOSPixelFormat pixelFormat = self.webRTCManager.frameConverter.detectedPixelFormat;
                NSString *formatString = [WebRTCFrameConverter stringFromPixelFormat:pixelFormat];
                [self updateFormatInfo:formatString];
                NSString *processingMode = self.webRTCManager.frameConverter.processingMode;
                [self updateProcessingMode:processingMode];
            }
            [self updateIconWithFormatInfo];
        });
    }
}

#pragma mark - Periodic Updates
- (void)startPeriodicUpdates {
    if (self.periodicUpdateTimer) {
        [self.periodicUpdateTimer invalidate];
    }
    
    self.periodicUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                               target:self
                                                             selector:@selector(updatePeriodicStats)
                                                             userInfo:nil
                                                              repeats:YES];
}

- (void)stopPeriodicUpdates {
    if (self.periodicUpdateTimer) {
        [self.periodicUpdateTimer invalidate];
        self.periodicUpdateTimer = nil;
    }
}

- (void)updatePeriodicStats {
    if (!self.isPreviewActive || !self.isReceivingFrames) {
        return;
    }
    if (self.webRTCManager) {
        float estimatedFps = [self.webRTCManager getEstimatedFps];
        if (estimatedFps > 0) {
            self.currentFps = estimatedFps;
            if (self.dimensionsLabel) {
                NSString *infoText = [NSString stringWithFormat:@"%dx%d @ %.0ffps",
                                   (int)self.lastFrameSize.width,
                                   (int)self.lastFrameSize.height,
                                   self.currentFps];
                self.dimensionsLabel.text = infoText;
            }
        }
        if (self.webRTCManager.frameConverter) {
            IOSPixelFormat pixelFormat = self.webRTCManager.frameConverter.detectedPixelFormat;
            NSString *formatString = [WebRTCFrameConverter stringFromPixelFormat:pixelFormat];
            if (![formatString isEqualToString:self.currentPixelFormat]) {
                [self updateFormatInfo:formatString];
            }
            NSString *processingMode = self.webRTCManager.frameConverter.processingMode;
            if (![processingMode isEqualToString:self.currentProcessingMode]) {
                [self updateProcessingMode:processingMode];
            }
        }
    }
}

@end

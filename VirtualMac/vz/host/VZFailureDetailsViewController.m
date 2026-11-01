#import "VZFailureDetailsViewController.h"
#import "VZAppSettings.h"
#import "VZDiagnostics.h"
#import "VZLocalization.h"
#import "VZSupport.h"

@interface VZFailureCell : UITableViewCell
@property(nonatomic, assign) BOOL alignsImageToTop;
@end

@implementation VZFailureCell

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!self.alignsImageToTop || !self.imageView.image)
        return;
    CGRect frame = self.imageView.frame;
    frame.origin.y = self.textLabel.frame.origin.y;
    self.imageView.frame = frame;
}

@end

static NSAttributedString *VZTitleWithBadge(NSString *title,
                                             NSString *badgeText)
{
    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIFont *badgeFont = [UIFont systemFontOfSize:12.0
        weight:UIFontWeightSemibold];
    CGSize textSize = [badgeText sizeWithAttributes:@{NSFontAttributeName:
        badgeFont}];
    CGSize badgeSize = CGSizeMake(ceil(textSize.width) + 14.0,
                                  ceil(textSize.height) + 6.0);
    UIView *badgeView = [[[UIView alloc] initWithFrame:
        (CGRect){CGPointZero, badgeSize}] autorelease];
    badgeView.backgroundColor = UIColor.tertiarySystemFillColor;
    badgeView.layer.cornerRadius = 7.0;
    badgeView.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *label = [[[UILabel alloc] initWithFrame:badgeView.bounds]
        autorelease];
    label.text = badgeText;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = badgeFont;
    label.textAlignment = NSTextAlignmentCenter;
    [badgeView addSubview:label];
    UIGraphicsImageRenderer *renderer = [[[UIGraphicsImageRenderer alloc]
        initWithSize:badgeSize] autorelease];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
            [badgeView.layer renderInContext:context.CGContext];
        }];
    NSTextAttachment *attachment = [[[NSTextAttachment alloc] init]
        autorelease];
    attachment.image = image;
    CGFloat badgeBaseline = round((titleFont.ascender + titleFont.descender -
        badgeSize.height) / 2.0);
    attachment.bounds = CGRectMake(0, badgeBaseline, badgeSize.width,
                                   badgeSize.height);
    NSMutableAttributedString *result = [[[NSMutableAttributedString alloc]
        initWithString:[title stringByAppendingString:@"  "] attributes:@{
            NSFontAttributeName: titleFont,
            NSForegroundColorAttributeName: UIColor.labelColor,
        }] autorelease];
    [result appendAttributedString:[NSAttributedString
        attributedStringWithAttachment:attachment]];
    return result;
}

@interface VZFailureDetailsViewController ()
@property(nonatomic, copy) NSString *failureTitle;
@property(nonatomic, copy) NSString *failureMessage;
@property(nonatomic, copy) NSString *details;
@property(nonatomic, assign) VZFailureSupportOptions options;
@property(nonatomic, copy) NSString *destructiveActionTitle;
@property(nonatomic, copy) void (^destructiveActionHandler)(void);
@property(nonatomic, assign) BOOL diagnosticsSaving;
@property(nonatomic, assign) BOOL diagnosticsSaved;
@property(nonatomic, assign) BOOL screenRecordingCompleted;
@property(nonatomic, assign) BOOL explainedLateScreenRecording;
- (void)refreshStepWithKind:(NSString *)kind;
- (UIView *)accessoryViewForStepKind:(NSString *)kind;
@end

@implementation VZFailureDetailsViewController

- (instancetype)initWithTitle:(NSString *)title
                       message:(NSString *)message
                       details:(NSString *)details
                       options:(VZFailureSupportOptions)options
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = VZL(@"Report Issue");
        self.failureTitle = title;
        self.failureMessage = message;
        self.details = details;
        self.options = options |
            VZFailureSupportOptionSuggestScreenRecording;
        self.screenRecordingCompleted = UIScreen.mainScreen.isCaptured;
        if (options & VZFailureSupportOptionSuggestDebugLogging)
            VZEnableDebugLoggingForNextBoot();
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(screenCaptureChanged:)
            name:UIScreenCapturedDidChangeNotification object:nil];
    }
    return self;
}

- (void)setDestructiveActionTitle:(NSString *)title
                          handler:(void (^)(void))handler
{
    self.destructiveActionTitle = title;
    self.destructiveActionHandler = handler;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88.0;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
        action:@selector(done:)] autorelease];
    self.preferredContentSize = CGSizeMake(640, 720);
}

- (NSArray<NSDictionary *> *)steps
{
    NSMutableArray *steps = [NSMutableArray array];
    if (self.options & VZFailureSupportOptionSuggestScreenRecording) {
        [steps addObject:@{
            @"kind": @"record",
            @"title": VZL(@"Record the Problem"),
            @"detail": self.screenRecordingCompleted ? @"" :
                VZL(@"Open Control Center and start Screen Recording, then reproduce the problem."),
        }];
    }
    [steps addObject:@{
        @"kind": @"diagnostics",
        @"title": VZL(@"Save Diagnostics to Files"),
        @"detail": VZL(@"Save a ZIP file containing logs and crash reports."),
    }];
    [steps addObject:@{
        @"kind": @"github",
        @"title": VZL(@"Create Github Issue"),
        @"detail": VZL(@"Describe the problem and attach the diagnostics ZIP and screen recording. If Safari cannot access Github, use a computer instead."),
    }];
    [steps addObject:@{
        @"kind": @"agent",
        @"title": VZL(@"Fix with Coding Agent"),
        @"detail": VZDeviceString(
            VZL(@"Install OpenSSH and LLDB from Sileo, connect your iPad to a computer, and ask Codex or Claude Code to diagnose and fix the issue. Share the solution on Github."),
            VZL(@"Install OpenSSH and LLDB from Sileo, connect your iPhone to a computer, and ask Codex or Claude Code to diagnose and fix the issue. Share the solution on Github.")),
    }];
    if (self.options & VZFailureSupportOptionDiagnosticsUnavailable) {
        NSUInteger diagnosticsIndex = 0;
        if (self.options & VZFailureSupportOptionSuggestScreenRecording)
            diagnosticsIndex = 1;
        [steps removeObjectAtIndex:diagnosticsIndex];
    }
    return steps;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    switch (section) {
    case 0: return 1;
    case 1: return self.steps.count;
    case 2: return self.destructiveActionTitle.length ? 1 : 0;
    default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 1) return VZL(@"Report This Problem");
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0 &&
        (self.options & VZFailureSupportOptionSuggestDebugLogging))
        return VZL(@"Debug logging has been enabled for the next boot.");
    return nil;
}

- (UITableViewCell *)textCellForTableView:(UITableView *)tableView
                               identifier:(NSString *)identifier
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[[VZFailureCell alloc] initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier] autorelease];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:
        UIFontTextStyleSubheadline];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [self textCellForTableView:tableView
            identifier:@"Failure"];
        ((VZFailureCell *)cell).alignsImageToTop = YES;
        cell.textLabel.text = self.failureTitle;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:
            UIFontTextStyleHeadline];
        NSMutableArray *parts = [NSMutableArray array];
        if (self.details.length && self.failureMessage.length &&
            [self.details containsString:self.failureMessage]) {
            [parts addObject:self.details];
        } else {
            if (self.failureMessage.length) [parts addObject:self.failureMessage];
            if (self.details.length) [parts addObject:self.details];
        }
        NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSMutableArray *trimmedParts = [NSMutableArray array];
        for (NSString *part in parts) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:whitespace];
            if (trimmed.length)
                [trimmedParts addObject:trimmed];
        }
        cell.detailTextLabel.text = [trimmedParts componentsJoinedByString:@"\n\n"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.image = [UIImage systemImageNamed:
            @"exclamationmark.triangle.fill"];
        cell.imageView.tintColor = UIColor.systemRedColor;
        return cell;
    }
    if (indexPath.section == 1) {
        NSDictionary *step = self.steps[indexPath.row];
        UITableViewCell *cell = [self textCellForTableView:tableView
            identifier:@"Step"];
        ((VZFailureCell *)cell).alignsImageToTop = YES;
        cell.textLabel.attributedText = nil;
        cell.textLabel.text = step[@"title"];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:
            UIFontTextStyleBody];
        cell.detailTextLabel.text = step[@"detail"];
        NSString *symbol = [NSString stringWithFormat:@"%ld.circle.fill",
            (long)indexPath.row + 1];
        UIImageSymbolConfiguration *numberConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:22.0
                weight:UIImageSymbolWeightRegular];
        cell.imageView.image = [UIImage systemImageNamed:symbol
            withConfiguration:numberConfiguration];
        cell.imageView.tintColor = UIColor.tertiaryLabelColor;
        NSString *kind = step[@"kind"];
        BOOL actionable = [kind isEqualToString:@"diagnostics"] ||
            [kind isEqualToString:@"github"];
        cell.selectionStyle = actionable ? UITableViewCellSelectionStyleDefault
                                         : UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.accessoryView = [self accessoryViewForStepKind:kind];
        if ([kind isEqualToString:@"agent"]) {
            cell.textLabel.attributedText = VZTitleWithBadge(
                step[@"title"], VZL(@"Optional"));
            cell.textLabel.accessibilityLabel = [NSString stringWithFormat:
                @"%@, %@", step[@"title"], VZL(@"Optional")];
        }
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Action"];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
            reuseIdentifier:@"Action"] autorelease];
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.textLabel.text = self.destructiveActionTitle;
    cell.textLabel.textColor = UIColor.systemRedColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UIView *)accessoryViewForStepKind:(NSString *)kind
{
    BOOL completed = ([kind isEqualToString:@"record"] &&
            self.screenRecordingCompleted) ||
        ([kind isEqualToString:@"diagnostics"] && self.diagnosticsSaved);
    if (completed) {
        UIImageView *checkmark = [[[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"checkmark.circle.fill"]] autorelease];
        checkmark.tintColor = UIColor.systemGreenColor;
        checkmark.contentMode = UIViewContentModeScaleAspectFit;
        checkmark.frame = CGRectMake(0, 0, 22, 22);
        return checkmark;
    }
    if ([kind isEqualToString:@"diagnostics"] && self.diagnosticsSaving) {
        UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]
            autorelease];
        spinner.frame = CGRectMake(0, 0, 20, 20);
        [spinner startAnimating];
        return spinner;
    }
    if ([kind isEqualToString:@"diagnostics"] ||
        [kind isEqualToString:@"github"]) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0
                weight:UIImageSymbolWeightSemibold];
        UIImageView *action = [[[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"arrow.up.right"
                withConfiguration:configuration]] autorelease];
        action.tintColor = UIColor.systemBlueColor;
        action.contentMode = UIViewContentModeScaleAspectFit;
        action.frame = CGRectMake(0, 0, 20, 20);
        return action;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        NSDictionary *step = self.steps[indexPath.row];
        NSString *kind = step[@"kind"];
        if ([kind isEqualToString:@"diagnostics"])
            [self saveDiagnostics];
        else if ([kind isEqualToString:@"github"]) {
            VZOpenSupportURL(VZReportIssueURLString);
        }
        return;
    }
    if (indexPath.section == 2 && self.destructiveActionHandler) {
        self.destructiveActionHandler();
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)refreshStepWithKind:(NSString *)kind
{
    NSUInteger row = [self.steps indexOfObjectPassingTest:
        ^BOOL(NSDictionary *step, NSUInteger index, BOOL *stop) {
            (void)index;
            if ([step[@"kind"] isEqualToString:kind]) {
                *stop = YES;
                return YES;
            }
            return NO;
        }];
    if (row == NSNotFound)
        return;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)row
        inSection:1];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell)
        return;
    NSDictionary *step = self.steps[row];
    cell.accessoryView = [self accessoryViewForStepKind:kind];
    if ([kind isEqualToString:@"record"]) {
        cell.detailTextLabel.text = step[@"detail"];
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
        }];
    }
}

- (void)saveDiagnostics
{
    if (self.diagnosticsSaving)
        return;
    self.diagnosticsSaving = YES;
    [self refreshStepWithKind:@"diagnostics"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *archive = VZCreateDiagnosticsArchive(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.diagnosticsSaving = NO;
            [self refreshStepWithKind:@"diagnostics"];
            if (!archive) {
                VZPresentFailureReport(self,
                    VZL(@"Couldn’t Export Diagnostics"),
                    error.localizedDescription, nil,
                    VZFailureSupportOptionDiagnosticsUnavailable);
                return;
            }
            UIDocumentPickerViewController *picker =
                [[[UIDocumentPickerViewController alloc]
                    initForExportingURLs:@[archive] asCopy:YES] autorelease];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        });
    });
}

- (void)screenCaptureChanged:(NSNotification *)notification
{
    (void)notification;
    if (!UIScreen.mainScreen.isCaptured || self.screenRecordingCompleted ||
        self.explainedLateScreenRecording)
        return;
    self.explainedLateScreenRecording = YES;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Record the Problem Again")
        message:VZL(@"Screen Recording started after the problem occurred, so it did not capture what happened.\n\nKeep recording, then repeat the steps that caused the problem. When this report appears again, save the diagnostics and attach both the screen recording and diagnostics ZIP to your Github issue.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    if (!urls.count)
        return;
    self.diagnosticsSaved = YES;
    [self refreshStepWithKind:@"diagnostics"];
}

- (void)done:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_failureTitle release];
    [_failureMessage release];
    [_details release];
    [_destructiveActionTitle release];
    [_destructiveActionHandler release];
    [super dealloc];
}

@end

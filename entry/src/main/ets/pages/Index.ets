import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError, cacheDownload, customConfig, distributedAccount, systemLoad } from '@kit.BasicServicesKit';

interface HealthMetric {
  label: string;
  value: string;
  detail: string;
  accent: string;
}

const PROTOCOL = 'https://';
const DOMAIN = 'developer.huawei.com';
const PATH = '/consumer/en/doc/harmonyos-references/js-apis-request-cachedownload?__json=true';
const CACHE_URL: string = `${PROTOCOL}${DOMAIN}${PATH}`;
const MEMORY_CACHE_LIMIT: number = 12 * 1024 * 1024;
const FILE_CACHE_LIMIT: number = 80 * 1024 * 1024;
const ACCOUNT_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
const LOG_TAG: string = 'SystemMonitor';

@Entry
@Component
struct Index {
  @State private systemLoadLevel: number = 1;
  @State private loadLabel: string = 'Normal';
  @State private loadColor: string = '#19C37D';
  @State private cacheBytes: number = 0;
  @State private cacheStatus: string = 'Idle';
  @State private accountName: string = 'Account';
  @State private accountState: string = 'Tap Account';
  @State private channelId: string = 'Unknown';
  @State private lastUpdated: string = '--:--';
  @State private notice: string = 'Ready';
  @State private metrics: HealthMetric[] = [];
  private actionCount: number = 0;

  private refreshTimer: number = -1;
  private cacheAvailable: boolean = true;

  private systemLoadListener = (level: systemLoad.SystemLoadLevel): void => {
    this.applySystemLoad(level);
    this.logInfo('systemLoadChange', `level=${Number(level)} label=${this.loadLabel}`);
    this.markAction('Load event');
  };

  private cacheSuccessListener = (): void => {
    this.cacheStatus = 'Cached';
    this.logInfo('cacheDownload.onDownloadSuccess', `url=${CACHE_URL}`);
    this.markAction('Cache done');
    this.refreshDownloadInfo();
  };

  private cacheErrorListener = (error: cacheDownload.DownloadError): void => {
    this.cacheStatus = 'Error';
    this.logInfo('cacheDownload.onDownloadError', `errorCode=${error.errorCode} message=${error.message}`);
    this.markAction('Cache error');
    this.rebuildMetrics();
  };

  aboutToAppear(): void {
    this.channelId = this.readChannelId();
    this.configureCacheDownload();
    this.registerLoadListener();
    this.refreshAll();
    this.refreshTimer = setInterval(() => {
      // eslint-disable-next-line
      this.refreshLoad();
      this.refreshDownloadInfo();
    }, 15000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.unregisterLoadListener();
    this.unregisterCacheListeners();
  }

  private async refreshAll(fromUser: boolean = false): Promise<void> {
    if (fromUser) {
      this.logInfo('BUTTON Refresh', 'clicked');
      this.markAction('Refresh');
    }
    await this.refreshLoad();
    this.refreshDownloadInfo();
    this.updateTimestamp();
    if (fromUser) {
      this.logInfo('BUTTON Refresh', `done level=L${this.systemLoadLevel} label=${this.loadLabel} cache=${this.cacheStatus} bytes=${this.cacheBytes}`);
      this.markAction('Refresh done');
    }
  }

  private async refreshLoad(): Promise<void> {
    try {
      const level: systemLoad.SystemLoadLevel = await systemLoad.getLevel();
      this.applySystemLoad(level);
      this.logInfo('systemLoad.getLevel', `level=${Number(level)} label=${this.loadLabel}`);
    } catch (error) {
      const err = error as BusinessError;
      this.logError('systemLoad.getLevel failed', err);
      this.markAction(`Load unavailable ${err.code}`);
    }
    this.updateTimestamp();
  }

  private async refreshAccount(): Promise<void> {
    this.logInfo('BUTTON Account', 'clicked');
    this.markAction('Account check');
    const canReadAccount: boolean = await this.ensureAccountPermission();
    if (!canReadAccount) {
      this.logInfo('BUTTON Account', `permission blocked state=${this.accountState}`);
      this.rebuildMetrics();
      this.updateTimestamp();
      return;
    }

    try {
      const accountAbility: distributedAccount.DistributedAccountAbility =
        distributedAccount.getDistributedAccountAbility();
      const info: distributedAccount.DistributedInfo = await accountAbility.getOsAccountDistributedInfo();
      this.accountName = this.formatAccountName(info);
      this.accountState = this.formatAccountEvent(info.event);
      this.logInfo('distributedAccount.getOsAccountDistributedInfo',
        `name=${info.name} id=${info.id} event=${info.event} nickname=${info.nickname ?? ''} state=${this.accountState}`);
      this.markAction('Account updated');
    } catch (error) {
      const err = error as BusinessError;
      this.accountName = 'No access';
      this.accountState = `Permission ${err.code}`;
      this.logError('distributedAccount.getOsAccountDistributedInfo failed', err);
      this.markAction(`Account blocked ${err.code}`);
    }
    this.rebuildMetrics();
    this.updateTimestamp();
  }

  private async ensureAccountPermission(): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        this.accountName = 'No access';
        this.accountState = 'Context unavailable';
        this.notice = 'Account permission context unavailable';
        this.logInfo('account permission', 'host context unavailable');
        return false;
      }

      const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, [ACCOUNT_PERMISSION]);
      const permissionIndex: number = result.permissions.indexOf(ACCOUNT_PERMISSION);
      const authResult: number = permissionIndex >= 0 ?
        result.authResults[permissionIndex] :
        abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;

      if (authResult === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.logInfo('account permission', `granted result=${authResult}`);
        return true;
      }

      this.accountName = 'No access';
      this.accountState = 'Permission denied';
      this.logInfo('account permission', `denied result=${authResult}`);
      this.markAction('Account denied');
    } catch (error) {
      const err = error as BusinessError;
      this.accountName = 'No access';
      this.accountState = `Permission request ${err.code}`;
      this.logError('account permission request failed', err);
      this.markAction(`Account request ${err.code}`);
    }
    return false;
  }

  private startCacheUpdate(): void {
    this.logInfo('BUTTON Cache', 'clicked');
    if (!this.cacheAvailable) {
      this.cacheStatus = 'Unavailable';
      this.logInfo('BUTTON Cache', 'cacheDownload unavailable on this device/emulator');
      this.markAction('Cache unavailable');
      this.rebuildMetrics();
      return;
    }

    try {
      this.cacheStatus = 'Downloading';
      cacheDownload.download(CACHE_URL, {
        cacheStrategy: cacheDownload.CacheStrategy.FORCE
      });
      this.logInfo('cacheDownload.download', `started url=${CACHE_URL} strategy=FORCE`);
      this.markAction('Cache start');
      setTimeout(() => {
        this.refreshDownloadInfo();
      }, 2000);
    } catch (error) {
      const err = error as BusinessError;
      this.cacheStatus = 'Error';
      this.logError('cacheDownload.download failed', err);
      this.markAction(`Cache failed ${err.code}`);
      this.rebuildMetrics();
    }
  }


  private clearCache(): void {
    this.logInfo('BUTTON Reset', 'clicked');
    this.cacheBytes = 0;
    if (!this.cacheAvailable) {
      this.cacheStatus = 'Local reset';
      this.logInfo('BUTTON Reset', 'local state reset because cacheDownload is unavailable');
      this.markAction('Reset done');
      this.rebuildMetrics();
      return;
    }

    try {
      cacheDownload.clearMemoryCache();
      cacheDownload.clearFileCache();
      this.cacheStatus = 'Cleared';
      this.logInfo('cacheDownload.clear', 'memory and file cache cleared');
      this.markAction('Cache reset');
    } catch (error) {
      const err = error as BusinessError;
      this.cacheStatus = 'Reset error';
      this.logError('cacheDownload.clear failed', err);
      this.markAction(`Reset failed ${err.code}`);
    }
    this.rebuildMetrics();
  }

  private configureCacheDownload(): void {
    try {
      cacheDownload.setMemoryCacheSize(MEMORY_CACHE_LIMIT);
      cacheDownload.setFileCacheSize(FILE_CACHE_LIMIT);
      cacheDownload.setDownloadInfoListSize(64);
      cacheDownload.onDownloadSuccess(CACHE_URL, this.cacheSuccessListener);
      cacheDownload.onDownloadError(CACHE_URL, this.cacheErrorListener);
      this.logInfo('cacheDownload.configure', `API23 memoryLimit=${MEMORY_CACHE_LIMIT} fileLimit=${FILE_CACHE_LIMIT}`);
    } catch (error) {
      const err = error as BusinessError;
      this.cacheAvailable = false;
      this.cacheStatus = 'Unavailable';
      this.logError('cacheDownload.configure failed', err);
      this.markAction('Cache unavailable');
    }
  }

  private refreshDownloadInfo(): void {
    if (!this.cacheAvailable) {
      this.cacheStatus = 'Unavailable';
      this.logInfo('cacheDownload.getDownloadInfo', 'skipped because cacheDownload is unavailable');
      this.rebuildMetrics();
      this.updateTimestamp();
      return;
    }
    if (this.cacheStatus === 'Cleared') {
      this.logInfo('cacheDownload.getDownloadInfo', 'skipped because cache was just cleared');
      this.rebuildMetrics();
      this.updateTimestamp();
      return;
    }

    try {
      const info: cacheDownload.DownloadInfo | undefined = cacheDownload.getDownloadInfo(CACHE_URL);
      if (info === undefined) {
        this.cacheStatus = this.cacheStatus === 'Downloading' ? 'Downloading' : 'No sample';
        this.logInfo('cacheDownload.getDownloadInfo', `undefined status=${this.cacheStatus}`);
      } else {
        this.cacheBytes = Math.max(0, info.resource.size);
        this.cacheStatus = info.resource.size > 0 ? 'Cached' : 'Failed';
        this.logInfo('cacheDownload.getDownloadInfo',
          `size=${info.resource.size} ip=${info.network.ip ?? ''} totalTime=${info.performance.totalTime} status=${this.cacheStatus}`);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.cacheStatus = 'Info blocked';
      this.logError('cacheDownload.getDownloadInfo failed', err);
      this.markAction(`Cache info ${err.code}`);
    }
    this.rebuildMetrics();
    this.updateTimestamp();
  }

  private registerLoadListener(): void {
    try {
      systemLoad.on('systemLoadChange', this.systemLoadListener);
      this.logInfo('systemLoad.on', 'systemLoadChange registered');
    } catch (error) {
      const err = error as BusinessError;
      this.logError('systemLoad.on failed', err);
      this.markAction(`Load listener ${err.code}`);
    }
  }

  private unregisterLoadListener(): void {
    try {
      systemLoad.off('systemLoadChange', this.systemLoadListener);
    } catch (error) {
      console.warn(`systemLoad listener cleanup failed: ${JSON.stringify(error)}`);
    }
  }

  private unregisterCacheListeners(): void {
    try {
      cacheDownload.offDownloadSuccess(CACHE_URL, this.cacheSuccessListener);
      cacheDownload.offDownloadError(CACHE_URL, this.cacheErrorListener);
      this.logInfo('cacheDownload.off', `url=${CACHE_URL}`);
    } catch (error) {
      console.warn(`cacheDownload listener cleanup failed: ${JSON.stringify(error)}`);
    }
  }

  private readChannelId(): string {
    try {
      const id: string = customConfig.getChannelId();
      const channel: string = id.length > 0 ? id : 'Default';
      this.logInfo('customConfig.getChannelId', `channel=${channel}`);
      return channel;
    } catch (error) {
      const err = error as BusinessError;
      this.logError('customConfig.getChannelId failed', err);
      return 'Unavailable';
    }
  }


  private applySystemLoad(level: systemLoad.SystemLoadLevel): void {
    const normalized: number = Math.max(0, Math.min(7, Number(level)));
    this.systemLoadLevel = normalized;
    this.loadLabel = this.getLoadLabel(normalized);
    this.loadColor = this.getLoadColor(normalized);
    this.rebuildMetrics();
  }

  private rebuildMetrics(): void {
    const loadValue: string = `L${this.systemLoadLevel}`;
    const loadDetail: string = `${this.loadLabel} via systemLoad`;
    const cachePercent: number = this.getCachePercent();

    this.metrics = [
      {
        label: 'CPU load',
        value: loadValue,
        detail: loadDetail,
        accent: this.loadColor
      },
      {
        label: 'Memory load',
        value: loadValue,
        detail: loadDetail,
        accent: '#4DA3FF'
      },
      {
        label: 'Thermal load',
        value: loadValue,
        detail: loadDetail,
        accent: '#FF8A4C'
      },
      {
        label: 'Cache storage',
        value: `${cachePercent}%`,
        detail: `${this.formatBytes(this.cacheBytes)} / ${this.formatBytes(FILE_CACHE_LIMIT)} ${this.cacheStatus}`,
        accent: this.getCacheAccent(cachePercent)
      },
      {
        label: 'Account sync',
        value: this.accountState,
        detail: this.accountName,
        accent: this.getAccountAccent()
      },
      {
        label: 'Custom config',
        value: this.channelId,
        detail: 'Device channel',
        accent: '#9AA8AE'
      }
    ];
  }

  private getCachePercent(): number {
    return Math.min(100, Math.max(0, Math.round((this.cacheBytes / FILE_CACHE_LIMIT) * 100)));
  }

  private getCacheAccent(percent: number): string {
    if (this.cacheStatus === 'Error' || this.cacheStatus === 'Reset error' || this.cacheStatus === 'Failed') {
      return '#FF5A5F';
    }
    if (percent >= 75) {
      return '#FF8A4C';
    }
    return '#D1E231';
  }

  private getAccountAccent(): string {
    if (this.accountState === 'Logged in') {
      return '#19C37D';
    }
    if (this.accountState === 'Permission denied' || this.accountState.startsWith('Permission')) {
      return '#FF5A5F';
    }
    return '#4DA3FF';
  }

  private getLoadLabel(level: number): string {
    const labels: string[] = ['Low', 'Normal', 'Medium', 'High', 'Overheated', 'Warning', 'Emergency', 'Escape'];
    return labels[level] ?? 'Unknown';
  }

  private getLoadColor(level: number): string {
    if (level <= 1) {
      return '#19C37D';
    }
    if (level <= 3) {
      return '#FFC857';
    }
    if (level <= 5) {
      return '#FF8A4C';
    }
    return '#FF5A5F';
  }

  private formatAccountName(info: distributedAccount.DistributedInfo): string {
    if (info.nickname !== undefined && info.nickname.length > 0) {
      return info.nickname;
    }
    if (info.name.length > 0) {
      return info.name;
    }
    if (info.id.length > 4) {
      return `ID ${info.id.substring(0, 4)}...`;
    }
    return 'Not logged in';
  }

  private formatAccountEvent(event: string): string {
    if (event === 'Ohos.account.event.LOGIN') {
      return 'Logged in';
    }
    if (event === 'Ohos.account.event.LOGOUT') {
      return 'Logged out';
    }
    if (event === 'Ohos.account.event.TOKEN_INVALID') {
      return 'Token invalid';
    }
    if (event === 'Ohos.account.event.LOGOFF') {
      return 'Logoff';
    }
    return event.length > 0 ? event : 'Sync idle';
  }

  private formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${bytes} B`;
  }

  private updateTimestamp(): void {
    // eslint-disable-next-line @performance/reuse-date-instances-check
    const now: Date = new Date();
    const hour: string = now.getHours().toString().padStart(2, '0');
    const minute: string = now.getMinutes().toString().padStart(2, '0');
    this.lastUpdated = `${hour}:${minute}`;
  }

  private markAction(message: string): void {
    this.actionCount += 1;
    // eslint-disable-next-line @performance/reuse-date-instances-check
    const now: Date = new Date();
    const hour: string = now.getHours().toString().padStart(2, '0');
    const minute: string = now.getMinutes().toString().padStart(2, '0');
    const second: string = now.getSeconds().toString().padStart(2, '0');
    this.notice = `${message} #${this.actionCount} ${hour}:${minute}:${second}`;
  }

  private logInfo(event: string, detail: string = ''): void {
    const suffix: string = detail.length > 0 ? ` | ${detail}` : '';
    console.info(`[${LOG_TAG}] ${event}${suffix}`);
  }

  private logError(event: string, error: BusinessError): void {
    console.error(`[${LOG_TAG}] ${event} | code=${error.code} message=${error.message}`);
  }

  @Builder
  private GaugePanel(): void {
    Stack({ alignContent: Alignment.Center }) {
      Progress({ value: this.systemLoadLevel, total: 7, type: ProgressType.Ring })
        .width(68)
        .height(68)
        .color(this.loadColor)
        .backgroundColor('#212A30')
        .style({ strokeWidth: 10 })

      Column({ space: 2 }) {
        Text(`L${this.systemLoadLevel}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F7FAFC')
        Text(this.loadLabel)
          .fontSize(12)
          .fontColor(this.loadColor)
        Text('System')
          .fontSize(10)
          .fontColor('#9AA8AE')
      }
    }
    .width('100%')
    .height(72)
  }

  @Builder
  private LoadStrip(): void {
    Row({ space: 5 }) {
      Column({ space: 1 }) {
        Text('CPU')
          .fontSize(8)
          .fontColor('#7F9098')
          .maxLines(1)
        Text(`L${this.systemLoadLevel}`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.loadColor)
          .maxLines(1)
      }
      .width('31%')
      .height(25)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#11181C')
      .borderRadius(8)
      .border({ width: 1, color: '#22313A' })

      Column({ space: 1 }) {
        Text('MEM')
          .fontSize(8)
          .fontColor('#7F9098')
          .maxLines(1)
        Text(`L${this.systemLoadLevel}`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4DA3FF')
          .maxLines(1)
      }
      .width('31%')
      .height(25)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#11181C')
      .borderRadius(8)
      .border({ width: 1, color: '#22313A' })

      Column({ space: 1 }) {
        Text('THM')
          .fontSize(8)
          .fontColor('#7F9098')
          .maxLines(1)
        Text(`L${this.systemLoadLevel}`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FF8A4C')
          .maxLines(1)
      }
      .width('31%')
      .height(25)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#11181C')
      .borderRadius(8)
      .border({ width: 1, color: '#22313A' })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private StatusChip(label: string, value: string, color: string): void {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(9)
        .fontColor('#7F9098')
        .maxLines(1)
      Text(value)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('48%')
    .height(36)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#11181C')
    .borderRadius(8)
    .border({ width: 1, color: '#22313A' })
  }

  @Builder
  private MetricRow(metric: HealthMetric): void {
    Column({ space: 5 }) {
      Row() {
        Text(metric.label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F7FAFC')
          .maxLines(1)
        Blank()
        Text(metric.value)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(metric.accent)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Text(metric.detail)
        .fontSize(10)
        .fontColor('#9AA8AE')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor('#11181C')
    .borderRadius(8)
    .border({ width: 1, color: '#22313A' })
  }

  @Builder
  private ActionButton(label: string, action: () => void): void {
    Button(label)
      .width(82)
      .height(20)
      .fontSize(10)
      .fontColor('#F7FAFC')
      .backgroundColor('#22313A')
      .borderRadius(6)
      .onClick(action)
  }

  @Builder
  private PrimaryButton(label: string, action: () => void): void {
    Button(label)
      .width(82)
      .height(20)
      .fontSize(10)
      .fontColor('#061012')
      .backgroundColor('#D1E231')
      .borderRadius(6)
      .onClick(action)
  }

  @Builder
  private NoticePill(): void {
    Text(this.notice)
      .height(19)
      .width('100%')
      .fontSize(10)
      .fontColor('#DDE7EA')
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .backgroundColor('#162027')
      .borderRadius(8)
      .border({ width: 1, color: '#2C3B44' })
  }

  @Builder
  private ActionDock(): void {
    Column({ space: 3 }) {
      Row({ space: 8 }) {
        this.PrimaryButton('Refresh', () => {
          this.refreshAll(true);
        })
        this.ActionButton('Cache', () => {
          this.startCacheUpdate();
        })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 8 }) {
        this.ActionButton('Reset', () => {
          this.clearCache();
        })
        this.ActionButton('Account', () => {
          this.refreshAccount();
        })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Row() {
        Blank()

        Column({ space: 4 }) {
          Column({ space: 2 }) {
            Text('Monitor')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F7FAFC')
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .width('100%')
            Text(`CH ${this.channelId} | ${this.lastUpdated}`)
              .fontSize(9)
              .fontColor('#9AA8AE')
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          this.NoticePill()

          this.GaugePanel()

          this.LoadStrip()

          this.ActionDock()

          Row({ space: 6 }) {
            this.StatusChip('Cache', this.cacheStatus, '#D1E231')
            this.StatusChip(this.accountName, this.accountState, '#4DA3FF')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          ForEach(this.metrics, (metric: HealthMetric) => {
            this.MetricRow(metric)
          }, (metric: HealthMetric) => metric.label)
        }
        .width('82%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 6, bottom: 40 })

        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#090D0F')
    .scrollBar(BarState.Off)
  }
}

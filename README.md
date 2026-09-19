---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 70895345140e721ad8079e6b0989f434_0151e4adb33f11f19369525400de85a5
    ReservedCode1: uk+WBouexmiRlq0g+wIDzN99wgwztb6U9rpKlJe3AL0wgWchrGWwxe4VoCmlUtOT03p1B9bg5YEXlVor6skslFiWd5nfqJRBZ1ALUAdCNO17VRluFG2w/wXGzYWvoeRzwYWLTb0DO3n8oMt1Ea9iXTkm55VaBT3yt5Gr4PdcaZDkiptjzqo3E8TZew0=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 70895345140e721ad8079e6b0989f434_0151e4adb33f11f19369525400de85a5
    ReservedCode2: uk+WBouexmiRlq0g+wIDzN99wgwztb6U9rpKlJe3AL0wgWchrGWwxe4VoCmlUtOT03p1B9bg5YEXlVor6skslFiWd5nfqJRBZ1ALUAdCNO17VRluFG2w/wXGzYWvoeRzwYWLTb0DO3n8oMt1Ea9iXTkm55VaBT3yt5Gr4PdcaZDkiptjzqo3E8TZew0=
---

# 天天油报 · iOS 版（自签分发）

手机流量直连各站云库读取营业额的 iOS 客户端。免服务器、免上架，用免费 Apple ID 自签安装到 iPhone。

---

## 一、它是什么

| 项 | 说明 |
|---|---|
| 形态 | iPhone 原生 App（SwiftUI），iPhone 竖屏 |
| 取数 | 手机 4G/5G 直连各站云库（SQL Server），不经任何中转服务器 |
| 数据口径 | 与桌面端一致：`TFuelTradeRecord`，按 `FBusinessDate` + `FBusinessShiftNo` 汇总 |
| 读到的内容 | 逐站当日营业额 / 各班次金额·油量·时段·交班状态 / 全天按油品 / 全天按支付方式 / 逐笔明细，可导出 CSV |
| 配置 | 站点与云库凭据以 AES-GCM 加密存本机，密钥存 iOS 钥匙串 |
| 账号 | 建议为手机端单独开**只读账号**，不要用 sa |

> 关键前提：站点云库必须是**公网可达**的。无公网云库的站点，手机端取不到数（与桌面端不同，桌面端在本机可走内网）。

---

## 二、工程结构

```
ttyb-ios/
├─ project.yml                     # XcodeGen 工程描述（含 SPM 依赖、AppIcon 资源）
├─ Sources/
│  ├─ TTYBApp.swift                # App 入口
│  ├─ Models.swift                 # 站点 / 班次 / 明细模型 + 交班状态与配色 + 格式化
│  ├─ ConfigStore.swift            # 加密配置存储（AES-GCM + Keychain）
│  ├─ DatabaseService.swift        # 云库连接与 SQL（SQLServerNIO 驱动）
│  ├─ RevenueService.swift         # 并发取数、交班判定（与电脑端 judge_shift_status 同法）
│  ├─ DayReportText.swift          # 详情纯文本（结构同电脑端详情窗口）
│  ├─ CSVExporter.swift            # 汇总 / 明细 CSV 导出（带 BOM，含交班状态列）
│  ├─ HomeView.swift               # 首页：站点列表，逐站展示各自营业额
│  ├─ StationDetailView.swift      # 单站：全天合计 + 各班次 + 按油品 + 按支付方式 + 明细
│  └─ SettingsView.swift           # 设置：站点增删改、批量导入（文件 / 剪贴板）导出、测试连接
├─ Resources/
│  └─ Assets.xcassets/
│     └─ AppIcon.appiconset/       # App 图标（1024 主图 + 12 个派生尺寸，共 13 个 PNG）
└─ .github/workflows/ios-build.yml # 云端 macOS 构建未签名 IPA
```

技术选型：**SQLServerNIO**（纯 Swift 的 TDS 协议客户端，SPM 一行接入，无需 FreeTDS 交叉编译）。

图标：`Resources/Assets.xcassets/AppIcon.appiconset/` 内含 1024 主图与 20 / 29 / 40 / 58 / 60 / 76 / 80 / 87 / 120 / 152 / 167 / 180 共 13 个不透明 PNG（深蓝渐变底 + 金黄柱状图 + 白色上升折线，与电脑端图标同风格），`Contents.json` 覆盖 iphone / ipad / ios-marketing 全部槽位；`project.yml` 已设 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`，构建即打出带图标的 App。

---

## 三、从零到装上手机（5 步）

### 第 1 步：把工程推上 GitHub

1. 打开 https://github.com/new ，新建仓库，名字如 `ttyb-ios`，选 **Public**（公有仓库的 macOS 构建额度免费），不要勾 README。
2. 在 Windows 上装 GitHub Desktop（https://desktop.github.com ），登录后 `File → Add local repository` 选中本工程目录，`Publish repository` 推上去。

### 第 2 步：等云端自动出 IPA

推送后，仓库页面 `Actions` 标签会自动跑 `Build unsigned IPA`，约 5–10 分钟。

- 绿色对勾 = 成功。点进该次运行，页面底部 `Artifacts` 下载 **TTYB-unsigned-ipa.zip**，解压得到 `TTYB-unsigned.ipa`。
- 红色叉 = 失败。把失败日志（`build-log` 工件）发给 Marvis，我来修。

> 这一步用的是 GitHub 免费的 macOS 构建机，不需要你有 Mac。

### 第 3 步：Windows 上给 IPA 签名并装进 iPhone

**推荐方式：Sideloadly（最省事）**

1. iPhone 用数据线连电脑，首次连接在手机上点"信任此电脑"。
2. 下载安装 Sideloadly：https://sideloadly.io
3. 电脑需装 **iTunes**（微软商店版即可，装来电驱）。
4. 打开 Sideloadly：`IPA` 选刚下载的 `TTYB-unsigned.ipa`，`Apple ID` 填你的 Apple ID，点 `Start`，按提示输入密码（含双重验证的验证码）。
5. 装完后，iPhone 上：`设置 → 通用 → VPN与设备管理 → 开发者App` 里**信任**你的 Apple ID 证书。
6. 回到桌面打开「天天油报」。

**注意**：
- 免费 Apple ID 签的应用 **7 天过期**，过期后 App 打不开，需重连电脑重签一次（数据不丢，配置还在）。
- 免费账号同时最多签 **3 个**自签应用。

**想免去 7 天重签（推荐进阶）：SideStore**

- 原理：手机端无线续签，不用连电脑。
- 需要：电脑装 AltServer 一次（仅首次配对用），手机装 SideStore + StosVPN（同为免费自签）。
- 教程：https://sidestore.io

**想一劳永逸：付费开发者账号（$99/年）**

- 签名有效期 1 年，最多 100 台设备（Ad Hoc 分发），无需重签。
- 警告：**绝对不要**用网上买的"企业证书签名"。那类证书由第三方持有，可直接读取你 App 内的云库凭据，40 个站点的数据库密码会全部外泄。只能用自己的 Apple ID 或自己的付费开发者账号签。

### 第 4 步：把站点配置导进手机

两种方式：

**方式 A：批量导入（40 个站点必用）**

1. 电脑端导出一份配置 JSON（用 `工具/export_mobile_config.py`，见该脚本头部说明；输出格式如下）。
2. 把 JSON 文件发到手机（微信文件传输助手 / AirDrop / iCloud 云盘 均可）。
3. App 里：点齿轮 → `批量导入配置`，两种载入方式任选：
   - **从文件导入**：点「从文件导入」，在系统「文件」App 中选中该 `.json` 文件，内容会自动载入编辑框；
   - **从剪贴板粘贴**：先把 JSON 全文复制到剪贴板，再点「从剪贴板粘贴」。
4. 核对编辑框内容后点右上角「导入」。**同名站点会被覆盖**（按站点名匹配，重名站点先替换后写入）。

JSON 格式（数组或 `{"stations":[...]}` 均可）：

```json
[
  {
    "name": "BF-000123 中石化XX站",
    "server": "1.2.3.4,51965",
    "db": "moms",
    "user": "readonly",
    "pwd": "********",
    "useTLS": false
  }
]
```

**方式 B：手工添加**：齿轮 → `添加站点`，逐项填写，点「测试连接」确认通了再保存。

> 导出的 JSON 含明文密码。导入完成后请删掉手机和电脑上的这个文件。

### 第 5 步：日常使用

- 打开 App 自动读取当天全部站点，列表里**逐站展示各自的营业额**（不再汇总成一个总营业额），标题栏下方显示站点数 / 笔数 / 已交班站数。
- 状态配色与电脑端一致：**已交班 = 绿字**（#0b7a3b），**未交班(营业中) = 红字**（#b3261e），未到交班点 = 红字提示，灰点 = 连不上（行内写明原因）。
- 下拉或底部按钮 = 刷新全部。
- 点进站点看详情，顺序与电脑端详情窗口一致：**全天合计 → 各班次明细（班次 / 营业额 / 油量 / 时段 / 状态）→ 全天按油品 → 全天按支付方式 → 逐笔明细**；右上角第一个按钮 = 复制全部（粘贴到微信/备忘录即为电脑端同款文本）。
- 首页右上角箭头 = 导出当日汇总 CSV（含各站交班状态、按油品、按支付方式三张表），可发微信/邮件，Excel 直接打开不乱码。

---

## 四、安全设计

| 项 | 做法 |
|---|---|
| 本地凭据 | AES-GCM 加密后写入 App 沙盒，密钥 32 字节随机生成存 iOS 钥匙串 |
| 传输 | 直连云库，不经过任何第三方服务器（也就没有服务器被拖库的风险） |
| 账号权限 | 建议手机端专用只读账号，最小权限 |
| 数据 | 只读查询，App 不做任何写库操作 |
| 分发 | 仅自签（自己的 Apple ID / 自己的开发者账号） |

---

## 五、已知限制（第一版）

1. 交班状态已接入桌面端同一套判定：取查询日前 6 天里班次最完整的一天作模板，把该班次的开始/结束时刻平移到查询日，`now >= 结束时刻 + 3 分钟` 判「已交班」，已过开班时刻判「未交班(营业中)」；只有历史 6 天完全取不到模板时才回退到「最后一笔交易距今 > 90 分钟」的兜底判据。
2. 逐笔明细单次最多取 500 笔（够日常核账，超大站可后续调大）。
3. 启动未加口令/指纹锁（配置本身已加密）。需要的话下一版加。
4. 无公网云库的站点无法在手机端取数。
5. 未做后台自动刷新，打开 App 时拉取。
*（内容由AI生成，仅供参考）*

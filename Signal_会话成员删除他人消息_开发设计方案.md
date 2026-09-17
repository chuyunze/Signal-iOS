# Signal 会话成员删除他人消息开发设计方案

> 文档状态：实现对齐稿 1.4
> 适用范围：基于 Signal-iOS 的自有测试版本
> 最后修订：2026-09-17
> 代码基线：`eec0a2f587`（2026-08-26）

### 当前实现补充（`jack-patch`）

- 删除后的标准 Signal 墓碑备份会在恢复时重建稳定 `MessageTargetKey`，防止同一目标内容再次落盘；现有备份协议不携带 Participant Delete 的删除者类型，因此恢复后仍保留墓碑语义，但不伪造删除者身份。
- 发起端保存发送当时本地已知的 `(recipientAci, deviceId)` 快照，并按逐设备回执展示“已在 X/Y 台已知设备确认”。该快照来自客户端当前收件人设备缓存，不等同于服务端权威活跃设备清单。
- 自己账号的关联设备处理 sent transcript 后也返回执行回执；同一请求 ID 若被复用于不同目标会被拒绝。
- 群请求的 `groupRevision` 高于本地 revision 时先持久化等待，群状态推进后重新校验请求者成员身份并执行；不会基于旧群状态提前删除。
- 已存引用回复按会话分页查找并清空原文、附件名称和缩略图引用；后到的引用若命中删除墓碑，只保存中性占位文本。
- `sendEnabled` 与 `receiveEnabled` 分离：停止发起新请求不影响已发布请求继续被兼容客户端识别。

## 1. 文档目的

本文档用于指导开发人员在 Signal-iOS 分支中实现以下能力：

- 在双人会话中，任意一方都可以请求把会话中的任意消息从双方账号的全部兼容设备上删除；
- 在群聊中，任意当前成员都可以把任意成员发送的消息从全体成员的全部兼容设备上删除，不要求管理员身份；
- 删除对象既可以是自己发送的消息，也可以是对方发送的消息；
- 删除请求支持多设备、发送端断网重试、接收端离线投递、乱序到达、重复投递，以及从删除后生成的兼容备份恢复等场景；
- 不修改 Signal Protocol 的密码学算法，不伪造原消息发送者身份；
- 群聊普通成员与管理员具有相同的会话内删除权限。

本文所说的“删除所有人的消息”均为**协作式、尽力而为的远程删除**，不是对远端设备的强制擦除。

本文进一步区分两种完成状态：

- **请求已发送/设备已确认**：可以只通过客户端协议实现；
- **所有兼容设备已确认**：必须知道发送时的预期设备集合，并按账号和设备聚合回执；当前纯客户端方案无法可靠证明该状态。

## 2. 首要结论与边界

### 2.1 现有 Signal 行为

Signal 当前的普通“为所有人删除”只允许原发送者删除自己近期发送的消息。官方帮助说明该操作是尽力而为，并明确指出引用回复不会随原消息一起删除。

Signal 群聊原生具有“管理员远程删除”：官方版本中，群管理员只能在限定时间内删除其他成员发送的消息。**这只是对官方现状的说明，不是本方案的限制。**本项目会改变这条产品规则：所有当前群成员均可删除本群任意成员发送的任意历史消息，**不设置任何时间限制**。

### 2.2 本需求不能只改界面判断

如果仅把“为所有人删除”按钮显示在收到的消息上，再调用现有普通远程删除消息，远端客户端会把删除请求的发送者识别为当前用户，而目标消息的作者是对方，二者不一致，因此请求应被拒绝。

不能通过以下方式实现：

- 删除客户端中的“必须是消息作者”判断；
- 删除或绕过现有 `adminDelete` 的管理员判断，把普通成员伪装成管理员；
- 伪造目标消息作者的 ACI、设备号或签名；
- 在数据库中按时间戳全局查找后直接删除；
- 先删除内容，再做权限校验。

这些做法会让同一种协议同时代表“管理员删除”和“任意成员删除”，难以区分，并可能误删其他群的消息。2026 年 Signal-iOS 的管理员删除处理曾修复过“破坏性操作发生在身份及群关系校验之前”的问题。因此本方案使用新的明确协议，并要求：**先确认请求者是当前群成员、目标属于当前群，再执行数据库或文件删除**。这里不限制普通成员的功能权限，只保证请求不会串群或破坏数据库。

### 2.3 能否作用于官方 Signal 客户端

不能保证。

新增的“会话成员删除”是自定义应用层协议。只有安装了兼容版本的 iOS、Android 或 Desktop 客户端才会识别并执行。未修改的官方 Signal 客户端通常会忽略未知字段，消息仍会保留。

因此：

- 双人会话双方、或群聊全体成员的设备都安装修改版：可以完成端到端验证；
- 对方或任一关联设备仍是官方版/旧版：该设备不会可靠删除；
- 想实现“所有手机都删除”：所有参与账号的所有活跃设备都必须支持该协议；
- 服务端无法替代客户端删除已落盘、已展示或已导出的明文。

### 2.4 推荐实现路线

本项目采用“新增独立的会话成员删除协议”方案：

```text
长按双人会话或群聊中的任意消息
    ↓
发送 ParticipantDeleteV1 加密控制消息
    ↓
Signal 服务端按普通端到端加密消息转发
    ↓
接收端验证会话、当前成员身份和目标消息
    ↓
把目标消息改成不可恢复的本地墓碑，并清理可渲染内容
    ↓
通过现有 sent transcript 同步到发起账号的关联设备
    ↓
兼容设备按账号和 sourceDeviceId 返回执行回执
```

`ParticipantDeleteV1` 同时支持双人会话与 Group V2 群聊。群聊中只要请求者是当前正式成员，就可以删除本群任何作者的消息，不检查管理员身份。

当前代码中的普通 Remote Delete 和 Admin Delete 已提供精确消息查找、编辑版本处理、墓碑化、附件引用解除、搜索索引更新、通知撤销、sent transcript 和备份墓碑等可复用能力。但现有 `TSMessage.remotelyDeleteMessage` 同时包含官方删除时间窗，不能由新协议直接调用。实现前必须把“授权/时间策略”和“已授权后的墓碑执行”拆开，新协议只能调用后者。

## 3. 产品规则

### 3.1 会话权限策略

定义统一策略枚举：

```swift
enum RemoteDeletePolicy {
    case anyParticipantInDirectChat
    case anyCurrentGroupMember
}
```

规则如下：

| 会话类型 | 目标消息 | 允许删除者 | 协议路径 |
| --- | --- | --- | --- |
| 双人会话 | 自己发送 | 会话任意一方 | Participant Delete V1 |
| 双人会话 | 对方发送 | 会话另一方 | 新增 Participant Delete V1 |
| 群聊 | 自己发送 | 任意当前正式成员 | Participant Delete V1 |
| 群聊 | 任意成员发送 | 任意当前正式成员 | 新增 Participant Delete V1 |

现有 Remote Delete 和 Admin Delete 可以继续保留以兼容官方语义，但本测试构建的“从所有设备删除”统一走 `ParticipantDeleteV1`，包括删除自己发送的消息。这样不会继承官方 Remote Delete 的时间限制。

本文的“任意消息”指具有明确作者和发送时间戳的用户消息，即 `TSIncomingMessage`、`TSOutgoingMessage` 及其受支持子类。群组变更、通话记录、错误提示、日期分隔等本地或系统 interaction 不属于成员发送的消息，不进入本协议。支付、礼物、投票、一次性查看等特殊消息类型必须逐类验证现有墓碑执行器能完整清除内容；未通过专项测试前不应仅因它们继承 `TSMessage` 就开放入口。

### 3.2 不设置删除时间窗

当前调试版本不限制目标消息年龄，以满足“任意消息都能删除”。无论消息发送于几分钟前、几天前或更早，只要目标消息仍能在本群或双人会话中被定位，就允许发起全员删除。

实现时定义集中配置，不在 UI 和接收端分别硬编码：

```swift
enum ParticipantDeleteConfiguration {
    static let protocolVersion: UInt32 = 1
    static let allowsUnlimitedMessageAge = true
    static let sendEnabled = true    // 当前测试构建允许发起
    static let receiveEnabled = true // 可独立关闭；通常应长期保持接收兼容
}
```

发送端和接收端都不得添加 24 小时、48 小时等消息年龄判断。仍应拒绝明显晚于删除请求可信服务端时间的目标时间戳；这是防止错误数据命中未来消息，不属于历史消息时间限制。

### 3.3 用户可见操作

长按会话内的消息后：

- 自己发送的消息：显示“仅从我这里删除”和基于 `ParticipantDeleteV1` 的“从所有设备删除”；
- 对方发送的消息：显示“仅从我这里删除”和新增“从双方设备删除”；
- 群聊中任意成员发送的消息：所有当前成员都显示“从群内所有设备删除”；
- 调试版绝不因消息年龄隐藏删除入口；
- 会话成员的设备能力未知或存在不兼容设备：可以隐藏远程选项，或显示选项并在确认页明确提示“部分设备可能不会删除”。测试版本建议采用后者，便于验证兼容性。

确认文案建议：

```text
从会话成员的设备删除？

这会向会话中的兼容设备发送删除请求。已经看过、截图、转发、导出或保存在不兼容设备上的内容无法撤回。
```

### 3.4 删除后的展示

不直接移除整行消息记录，而是显示墓碑：

```text
你删除了这条消息
```

其他成员设备显示：

```text
某位成员删除了这条消息
```

墓碑不显示原正文、附件缩略图、链接预览或引用文本。它保留最小标识用于防止离线消息、编辑消息、备份恢复或重复投递把内容重新带回来。

## 4. 总体技术架构

### 4.1 分层设计

```text
Conversation UI
    │ 生成删除意图、确认、显示状态
    ▼
ParticipantDeleteCoordinator
    │ 测试构建的所有会话级删除统一走 Participant Delete
    ▼
ParticipantDeleteOutgoingMessage
    │ 编码 ParticipantDeleteV1，发送到会话成员和自己的关联设备
    ▼
现有 Signal 端到端加密与消息投递
    ▼
MessageReceiver
    │ 解析新控制消息
    ▼
ParticipantDeleteManager
    │ 校验成员与目标、处理乱序、写入墓碑、清理内容
    ▼
Message DB / Attachment Store / Search Index / Notification Store
```

### 4.2 不需要修改的部分

- Double Ratchet、Sesame、Sender Keys 等密码学实现；
- `libsignal` 的加密原语；
- 身份密钥和会话密钥格式；
- 附件加密算法；
- 推送通知提供商。

本功能属于端到端加密载荷中的**应用层控制消息**，应复用现有加密会话进行身份认证和保密传输。

## 5. 协议设计

### 5.1 为什么要新增协议类型

现有普通远程删除可以用“控制消息的发送者就是原消息作者”隐式确定目标作者。新需求中，删除请求者与目标作者不同，因此协议必须显式携带目标作者，并使用不同消息类型表达不同授权语义。

不要改变现有 Remote Delete 或 Admin Delete 的解释，否则旧逻辑、官方客户端兼容性和新测试规则会混在一起。群聊任意成员删除也使用独立的 `ParticipantDeleteV1`。

### 5.2 Protobuf 结构

在当前分支的数据消息定义中选取未使用字段号，新增类似结构。具体文件名和字段号以所使用的 Signal-iOS commit 为准：

```proto
message ParticipantDelete {
  uint32 version = 1;

  // 被删除消息作者的 ACI。请求者身份不得从此载荷读取，
  // 必须来自已认证的远端 envelope、本账号 sent transcript 或本地执行上下文。
  bytes targetAuthorAciBinary = 2;

  // Signal 现有消息定位的核心字段。
  uint64 targetSentTimestamp = 3;

  // 16 字节随机 UUID，用于幂等、回执和重放检测。
  bytes requestId = 4;

  // 仅用于诊断和排序，不能用于限制历史消息年龄。
  uint64 clientRequestedAt = 5;

  enum Scope {
    UNKNOWN = 0;
    DIRECT_CHAT_BOTH_ACCOUNTS = 1;
    GROUP_ALL_CURRENT_MEMBERS = 2;
  }
  Scope scope = 6;

  // 群聊时记录发起操作所见的 Group V2 revision；
  // 实际群标识仍从外层 groupV2 上下文推导，不信任本地 thread ID。
  optional uint32 groupRevision = 7;
}

message ParticipantDeleteReceipt {
  uint32 version = 1;
  bytes requestId = 2;

  enum Result {
    UNKNOWN = 0;
    APPLIED = 1;
    ALREADY_APPLIED = 2;
    TARGET_PENDING = 3;
    REJECTED_NOT_CURRENT_MEMBER = 4;
    REJECTED_NOT_SUPPORTED = 5;
    REJECTED_INVALID_TARGET = 6;
  }
  Result result = 3;
}
```

在 `DataMessage` 或当前等价的顶层内容消息中增加：

```proto
optional ParticipantDelete participantDelete = 30;
optional ParticipantDeleteReceipt participantDeleteReceipt = 31;
// NEXT ID: 32
```

当前代码基线中 `DataMessage` 的下一个字段号为 30，因此本文暂定使用 30、31。开发合入时仍须再次确认没有并行变更或上游占用；发生冲突时重新分配。生成代码必须使用仓库脚本重新生成，不手工编辑 `Generated` 目录。

`ParticipantDeleteReceipt` 应作为一对一加密控制消息发给原请求者账号，不作为群消息广播。接收端用经过认证的 `envelope.sourceAci + sourceDeviceId` 标识实际执行设备；载荷中不重复声明可伪造的设备身份。

是否增加新的 `DataMessage.ProtocolVersion` 必须作为明确的兼容性决策：

- 内部测试若希望旧客户端静默忽略本协议，可暂不提升 `requiredProtocolVersion`；
- 若提升协议版本，旧客户端可能显示“不支持的消息”占位，而不是静默保留；
- 无论选择哪种方式，都不能把旧客户端未报错解释为已经执行删除。

### 5.3 目标消息唯一键

统一定义：

```text
MessageTargetKey = (
    stableConversationId,
    targetAuthorAci,
    targetSentTimestamp
)
```

其中：

- `stableConversationId` 必须从当前已认证消息所在会话推导，不能信任载荷提供的本地标识；
- 双人会话使用本地账号 ACI 与对方 ACI 的规范化组合；
- 群聊使用外层 Group V2 上下文推导的稳定 groupId；
- 本地 `threadUniqueId` 或 thread row ID 只能作为查询加速字段，不能作为跨设备、备份或恢复后的稳定身份；
- 群聊目标作者可以是群内任何成员或已经离群但仍有历史消息的成员；
- 严禁只按 `targetSentTimestamp` 查找；
- 严禁跨 thread 全局查找后删除。

如果当前分支已经为消息提供稳定 UUID/server GUID，可把它作为额外匹配字段，但仍要验证作者、时间戳和会话范围。

### 5.4 请求者身份来源

远端请求的真实请求者必须取自通过现有 Signal 会话认证的：

```swift
envelope.sourceAci
```

本账号 sent transcript 的请求者取经过认证的本地账号 ACI，并同时验证来源设备是本账号合法关联设备；本地立即执行使用当前注册账号 ACI。即使协议载荷未来增加 `requesterAci`，也只能用于调试，不能用于权限判断。载荷中的请求者身份可以被自定义客户端任意填写。

### 5.5 能力协商

新增能力位：

```text
participantDeleteV1
```

当前分支的账号能力通过服务端 Profile/Account Attributes 发布，不是增加一个本地枚举即可完成。正式接入 `participantDeleteV1` 能力位需要服务端和各平台配合。如果内部测试阶段不修改服务端，则使用以下降级规则：

1. 本地功能开关开启后允许发送；
2. 对端兼容设备执行并返回回执；
3. 收到回执时只显示“已有设备确认删除”或确认数量；
4. 在不知道预期设备集合时，不显示“全部兼容设备已删除”；
5. 不把服务端投递成功等同于远端已执行；
6. 旧客户端忽略未知消息时，不显示“已从所有设备删除”。

如果产品必须显示“所有兼容设备已确认”，则服务端或自有基础设施必须向发送端提供发送时的预期设备快照；回执按 `(requestId, responderAci, sourceDeviceId)` 聚合。设备在请求后新关联、解绑或长时间不活跃时的计算规则也必须预先定义。

## 6. 接收端有效性与成员关系校验

本测试版本不区分群管理员和普通成员。这里的校验只用于确认请求来自当前会话成员、目标属于同一会话，并防止串群、错误时间戳或重复数据破坏调试结果。

### 6.1 强制校验顺序

必须按以下顺序执行，任一失败都不得修改消息或附件：

1. Protobuf 可解析且 `version == 1`；
2. `requestId` 长度、目标 ACI 和时间戳格式合法；
3. 明确请求来源是远端 envelope、本账号 sent transcript，还是本地立即执行；
4. 远端或 sent transcript 必须具有经过现有加密会话认证的 `envelope.sourceAci` 和 `sourceDeviceId`；
5. 当前 thread 是双人会话或 Group V2 群聊，不是 Note to Self 或未知 thread；
6. 双人远端请求中，请求者必须是该会话另一方；本账号 sent transcript 必须来自本账号合法关联设备；
7. 双人会话的目标作者只能是本地账号或会话对方；
8. 群聊中请求者必须是当前正式成员，不检查 `isAdministrator`；
9. 目标键绑定当前 thread，不能跨双人会话或跨群查找；
10. 目标消息存在时，其真实作者和时间戳必须与请求完全匹配；
11. 网络接收请求的目标时间戳不能晚于可信服务端时间，但不检查目标消息距今已有多久；本地立即执行按“目标已存在且精确匹配”判断，不使用 `serverTimestamp == 0` 代替可信时间；
12. 重复请求满足幂等规则；
13. 所有校验通过后，才开始数据库事务与内容清理。

群聊示例：C 删除群 G 中 A 发送的消息时，在所有成员设备上都应得到同一关系：

```text
requester = C
requesterIsCurrentFullMemberOfGroupG = true
targetAuthor = A
targetThread = Group G
requiresAdministrator = false
```

A 可以是当前成员，也可以是已经离群但仍在群历史中留下消息的成员。判断依据是目标消息确实位于 Group G，而不是要求 A 当前仍在群中。

### 6.2 校验伪代码

```swift
enum ParticipantDeleteOrigin {
    case remoteEnvelope(requester: Aci, sourceDeviceId: DeviceId)
    case localSentTranscript(localAci: Aci, sourceDeviceId: DeviceId)
    case localInitiation(localAci: Aci)
}

func validate(
    request: ParticipantDelete,
    origin: ParticipantDeleteOrigin,
    thread: TSThread,
    trustedServerTimestamp: UInt64?,
    tx: DBReadTransaction
) throws -> ValidatedParticipantDelete {
    guard request.version == 1 else { throw .unsupportedVersion }
    guard request.requestId.count == 16 else { throw .invalidRequestId }

    let requester: Aci
    switch origin {
    case .remoteEnvelope(let authenticatedRequester, _):
        requester = authenticatedRequester
    case .localSentTranscript(let localAci, _), .localInitiation(let localAci):
        requester = localAci
    }

    let targetAuthor = try Aci.parseFrom(
        serviceIdBinary: request.targetAuthorAciBinary
    )

    let scope: ParticipantDeleteScope
    switch thread {
    case let contactThread as TSContactThread:
        guard request.scope == .directChatBothAccounts else { throw .scopeMismatch }
        guard let localAci = accountManager.localIdentifiers(tx: tx)?.aci else {
            throw .missingLocalIdentity
        }
        switch origin {
        case .remoteEnvelope:
            guard contactThread.contactAci == requester else { throw .wrongConversation }
        case .localSentTranscript, .localInitiation:
            guard requester == localAci else { throw .wrongConversation }
        }
        guard targetAuthor == localAci || targetAuthor == contactThread.contactAci else {
            throw .invalidTargetAuthor
        }
        scope = .direct(
            stableConversationId: StableConversationId.direct(localAci, contactThread.contactAci),
            localThreadUniqueId: contactThread.uniqueId
        )

    case let groupThread as TSGroupThread:
        guard request.scope == .groupAllCurrentMembers else { throw .scopeMismatch }
        guard let groupModel = groupThread.groupModel as? TSGroupModelV2 else {
            throw .unsupportedGroup
        }
        guard groupModel.membership.isFullMember(requester) else {
            throw .requesterIsNotCurrentMember
        }
        // 特意不检查 isFullMemberAndAdministrator。
        scope = .group(
            stableConversationId: StableConversationId.group(groupThread.groupModel.groupId),
            localThreadUniqueId: groupThread.uniqueId
        )

    default:
        throw .invalidThread
    }

    if let trustedServerTimestamp {
        guard request.targetSentTimestamp <= trustedServerTimestamp else {
            throw .futureTarget
        }
    }
    return ValidatedParticipantDelete(
        requestId: request.requestId,
        requester: requester,
        scope: scope,
        target: MessageTargetKey(
            stableConversationId: scope.stableConversationId,
            localThreadUniqueId: thread.uniqueId,
            authorAci: targetAuthor,
            sentTimestamp: request.targetSentTimestamp
        )
    )
}
```

目标消息查到后，还要在删除前断言：

```swift
guard target.uniqueThreadId == validated.target.localThreadUniqueId else {
    throw .wrongConversation
}
guard target.authorAci == validated.target.authorAci else {
    throw .invalidTargetAuthor
}
guard target.timestamp == validated.target.sentTimestamp else {
    throw .invalidTargetTimestamp
}
```

### 6.3 先校验后删除

代码结构必须明确分成两个阶段：

```swift
let validated = try validator.validate(..., tx: transaction)
try manager.apply(validated, tx: transaction)
```

禁止在 `validate` 内调用 `markMessageAsRemotelyDeleted`、删除附件或写入墓碑。单元测试需验证所有拒绝分支都不会产生数据库副作用。这个要求不限制群成员的删除权限，只用于保证调试数据一致。

## 7. 数据模型与墓碑设计

### 7.1 已收到目标消息

目标消息存在时，复用 Signal 现有远程删除模型，把原 interaction 转换为墓碑，并补充删除者元数据。数据模型拆成“请求/发送状态”和“目标删除事实”两部分，避免 interaction 删除后丢失防复活依据。

请求与发送状态：

```text
ParticipantDeleteRequest
------------------------
requestId               BLOB    PRIMARY KEY
requesterAci             BLOB    NOT NULL
requesterDeviceId        INTEGER NULL
stableConversationId     BLOB    NOT NULL
targetAuthorAci          BLOB    NOT NULL
targetSentTimestamp      INTEGER NOT NULL
requestServerTimestamp   INTEGER NULL
protocolVersion          INTEGER NOT NULL
localProcessingState     INTEGER NOT NULL
outgoingSendState        INTEGER NULL
expectedDeviceSnapshot   BLOB    NULL
createdAt                INTEGER NOT NULL
```

逐设备回执：

```text
ParticipantDeleteDeviceReceipt
------------------------------
requestId               BLOB    NOT NULL
responderAci             BLOB    NOT NULL
responderDeviceId        INTEGER NOT NULL
result                   INTEGER NOT NULL
receivedAt               INTEGER NOT NULL

PRIMARY KEY(requestId, responderAci, responderDeviceId)
```

当前实现写入客户端在发送时缓存的“已知设备快照”，用于显示 `X/Y 台已知设备确认`；它不是服务端权威活跃设备集合。只有服务端/自有基础设施提供权威快照后，才能把该集合用于“全部预期兼容设备已确认”的产品承诺；快照为空时只能计算已有设备确认。

长期目标墓碑：

```text
ParticipantDeleteTombstone
--------------------------
stableConversationId      BLOB    NOT NULL
localThreadUniqueId       TEXT    NULL
targetAuthorAci           BLOB    NOT NULL
targetSentTimestamp       INTEGER NOT NULL
interactionId             INTEGER NULL
firstRequestId            BLOB    NOT NULL
requesterAci              BLOB    NOT NULL
appliedAt                 INTEGER NOT NULL
protocolVersion           INTEGER NOT NULL

UNIQUE(stableConversationId, targetAuthorAci, targetSentTimestamp)
```

`interactionId` 只用于快速关联 UI，不得设置成墓碑记录的生命周期所有者；即使 interaction 因消息过期、用户本地清理或迁移而删除，稳定目标键仍需按产品保留策略存在。相同目标的后续不同 `requestId` 直接合并为 `ALREADY_APPLIED`，不能因目标唯一索引冲突而报错。

原消息 interaction 应保留：

- thread 唯一标识；
- 原作者 ACI 的本地映射；
- 原发送时间戳；
- 远程删除状态；
- 删除方式 `participantDelete`；
- 删除者，用于墓碑文案。

必须清除：

- 正文和正文范围；
- 附件引用和密钥立即解除，本地孤儿文件进入可重试清理；
- 缩略图、波形、贴纸渲染缓存；
- 联系人卡片、位置、支付说明等可渲染内容；
- 链接预览及 Open Graph 缓存引用；
- 搜索索引；
- 媒体库索引；
- 分享、转发和回复草稿中的该消息快照；
- 未展示的本地通知内容。

当前通用墓碑函数不会自动覆盖所有特殊子类的业务记录。支付交易账本、礼物状态、投票选项/投票记录等应逐类定义：哪些只是消息渲染数据需要清除，哪些是独立业务或合规记录只能解除消息展示关联。不能为了满足 UI 墓碑而误删独立资金或审计数据。

### 7.2 删除请求先于目标消息到达

离线、多设备和服务端队列会造成删除请求先到、原消息后到。新增待处理墓碑表：

```text
PendingParticipantDelete
------------------------
firstRequestId          BLOB NOT NULL
stableConversationId    BLOB NOT NULL
localThreadUniqueId     TEXT NULL
targetAuthorAci         BLOB NOT NULL
targetSentTimestamp     INTEGER NOT NULL
requesterAci            BLOB NOT NULL
requesterDeviceId       INTEGER NULL
requestServerTimestamp  INTEGER NOT NULL
conversationScope       INTEGER NOT NULL
groupRevision           INTEGER NULL
expiresAt               INTEGER NOT NULL
protocolVersion         INTEGER NOT NULL

PRIMARY KEY(stableConversationId, targetAuthorAci, targetSentTimestamp)
```

处理规则：

1. 先完成不依赖目标内容的会话与当前成员关系校验；
2. 在当前 thread 范围内查不到目标消息时，写入 pending tombstone；
3. 后续插入任何新消息时，在附件下载和用户通知之前按 `MessageTargetKey` 查询 pending tombstone；
4. 命中时不落盘正文和附件，直接创建已删除墓碑；
5. 将 pending 记录标记为已消费，并把所有指向同一目标的 request 记录更新为 `APPLIED`，分别排队发送最终回执；
6. 群聊 pending 记录必须绑定 Group V2 thread，不能被其他群的同作者、同时间戳消息消费；
7. pending 记录至少保留到消息服务最大离线投递窗口之后，并加入必要的保留余量；
8. 增加每请求者、每会话和全局数量/容量上限，超过上限时记录匿名化指标并拒绝继续写入，防止合法群成员用不存在的目标耗尽数据库；
9. “允许删除任意历史消息”只表示已有历史目标不受年龄限制，不表示不存在目标的 pending 永久保存。

对于已经应用的墓碑，必须在所承诺的备份恢复和历史同步保留范围内持续保存最小目标键；具体清理策略必须与产品承诺一致，不能跟随 interaction 级联删除。

### 7.3 幂等性

- 同一 `requestId` 重复到达：不重复清理，返回 `ALREADY_APPLIED`；
- 不同 `requestId` 指向同一目标：目标已是墓碑时合并状态，不恢复也不重复删除文件；
- 已执行请求的结果不可被普通消息、编辑、反应或引用消息覆盖；
- `ParticipantDeleteRequest.requestId` 和 `ParticipantDeleteTombstone.MessageTargetKey` 分别建立唯一索引；
- 当前接收管线不会为所有瞬态控制消息创建 interaction，仅依赖 envelope 重复检测不足以保证本协议幂等，因此必须保留上述请求级索引。

## 8. 发送端流程

### 8.1 UI 到消息发送

```text
用户长按双人会话或群聊中的任意消息
  → ParticipantDeleteCoordinator 检查会话类型和成员状态，不检查消息年龄
  → 展示确认框
  → 生成随机 requestId
  → 在同一事务中创建本地请求记录和稳定目标墓碑，并把本地目标变为墓碑
  → 双人会话发给另一方；群聊按当前 Group V2 成员列表群发
  → 由现有 sent transcript 把相同操作同步给自己的其他关联设备
  → 更新发送状态
```

本地先变为墓碑可以立即反馈，但必须保留“正在发送”状态。如果最终失败，建议不要自动恢复敏感内容；显示“远端删除未确认”，并提供重试。

本地立即执行不使用伪造的 `serverTimestamp = 0` 走网络接收校验。它基于已存在的目标 interaction 完成 thread、作者和时间戳精确匹配，然后进入相同的已授权墓碑执行器。

### 8.2 发送状态机

```text
created
  └── queued
        ├── sent
        │     ├── deviceConfirmed
        │     ├── partiallyConfirmed
        │     ├── allExpectedDevicesConfirmed（仅在已知预期设备集合时）
        │     └── receiptTimeout
        ├── retryableFailure
        └── permanentFailure
```

状态含义：

| 状态 | 用户提示 |
| --- | --- |
| queued/sent | 正在从会话成员的设备删除 |
| deviceConfirmed | 至少有一台兼容设备已确认删除 |
| partiallyConfirmed | 已有多台设备确认，仍有设备未确认或预期集合未知 |
| allExpectedDevicesConfirmed | 发送时已知的全部预期兼容设备均已确认；无预期设备快照时不得进入此状态 |
| receiptTimeout | 删除请求已发送，但无法确认所有设备 |
| retryableFailure | 发送失败，可重试 |
| permanentFailure | 请求数据无效、发起者已不在群内，或接收端版本不支持 |

回执只能证明兼容客户端报告已执行，不能证明恶意客户端、截图或导出副本已被销毁。

回执聚合键为 `(requestId, responderAci, sourceDeviceId)`。群聊设备将回执作为一对一控制消息发给原请求者账号；原请求者的关联设备可通过 sent transcript 或专用本账号同步共享聚合状态。不得在群内广播每台设备的回执。

## 9. 接收端执行流程

### 9.1 主流程

```swift
func processParticipantDelete(
    _ proto: SSKProtoParticipantDelete,
    origin: ParticipantDeleteOrigin,
    thread: TSThread,
    trustedServerTimestamp: UInt64?,
    tx: DBWriteTransaction
) throws {
    // 1. 会话、成员关系和目标有效性检查必须首先完成。
    let validated = try validator.validate(
        proto,
        origin: origin,
        thread: thread,
        trustedServerTimestamp: trustedServerTimestamp,
        tx: tx
    )

    // 2. 请求级幂等检查。
    if let previousResult = requestStore.result(validated.requestId, tx: tx) {
        receiptQueue.enqueue(previousResult.receipt, tx: tx)
        return
    }

    // 3. 目标级幂等检查：不同 requestId 也不能重复执行。
    if tombstoneStore.contains(validated.target, tx: tx) {
        requestStore.recordAlreadyApplied(validated, tx: tx)
        receiptQueue.enqueue(.alreadyApplied(validated.requestId), tx: tx)
        return
    }

    // 4. 仅在当前 thread 中查找精确作者和时间戳。
    guard let target = interactionFinder.findMessage(
        timestamp: validated.target.sentTimestamp,
        threadId: validated.target.localThreadUniqueId,
        authorAci: validated.target.authorAci,
        tx: tx
    ) else {
        pendingStore.insertOrMerge(validated, tx: tx)
        requestStore.recordTargetPending(validated, tx: tx)
        receiptQueue.enqueue(.targetPending(validated.requestId), tx: tx)
        return
    }

    // 5. 原子地创建稳定墓碑并清理可渲染内容。
    try deleteStore.markAsParticipantDeleted(
        target,
        validatedDelete: validated,
        tx: tx
    )
    requestStore.recordApplied(validated, tx: tx)

    // 6. 事务内解除所有可渲染引用；事务提交后重试孤儿文件清理和回执发送。
    orphanCleanup.scheduleIfNeeded(target)
    receiptQueue.enqueue(.applied(validated.requestId), tx: tx)
}
```

### 9.2 原子性要求

数据库事务内完成：

- 会话、成员关系和目标检查所需数据读取；
- 目标消息状态变更；
- 附件引用解绑；
- 搜索/媒体索引删除标记；
- request、稳定 tombstone 或 pending tombstone 写入；
- 回执 outbox 记录写入；网络发送在事务提交后进行。

大文件物理删除可以复用当前附件存储的引用计数/孤儿清理机制，并在事务提交后执行，但必须可重试。即使物理文件暂时未删，数据库层也不能再暴露附件密钥、路径或渲染引用。验收时应分别验证“事务提交后不可访问”和“后台清理最终移除文件”，不能把二者混成同一个原子承诺。

## 10. 多设备同步

### 10.1 其他会话成员账号的设备

双人会话中，删除请求作为普通加密控制消息发送给另一方账号。群聊中，请求携带当前 Group V2 上下文，复用现有群消息发送管线分发给所有当前成员。现有多设备投递机制继续把请求送到每个成员账号的活跃设备；每台兼容设备独立确认请求者仍是当前成员，然后落墓碑并清理本地内容。

这里必须区分：服务端“向账号投递成功”、某一设备返回执行回执、客户端已知设备均返回回执，以及服务端权威预期设备均返回回执。当前纯客户端实现可以显示前三种中的“已知设备确认进度”，但不能把它表述为服务端意义上的全部活跃兼容设备完成。

### 10.2 自己账号的关联设备

发起删除的当前设备已经本地处理。当前代码中的 `TSOutgoingMessage` 默认生成 sent transcript，`TransientOutgoingMessage` 也继承该行为，因此首期必须优先复用现有 sent transcript：

- `OutgoingParticipantDeleteMessage` 编码相同的 `ParticipantDeleteV1`；
- sent transcript 携带原会话目标和相同 `requestId`；
- 只有现有 transcript 无法满足重试、状态聚合或跨平台兼容时，才新增 `ParticipantDeleteSyncV1`。

关联设备收到同步消息时：

- 验证同步消息来自本账号的合法关联设备；
- 使用同步消息对应的双人或 Group V2 thread 定位目标；
- 执行与普通接收端相同的墓碑/乱序逻辑；
- 不再次把请求发送给对方，避免循环。

validator 必须接收显式 origin。双人会话的远端 envelope 要求 requester 等于 contact ACI；本账号 sent transcript 则要求 requester 等于本地 ACI。不能用同一条“requester 必须等于 contact ACI”的判断处理两种来源。

### 10.3 新增关联设备与备份恢复

如果历史同步或备份把原消息恢复出来，删除也会失效。因此：

- 当前实现复用标准 Signal 的 remote-delete tombstone 聊天项；恢复该聊天项后，立即以作者、发送时间戳和稳定会话标识重建 `ParticipantDeleteTombstone`，从而恢复稳定 `MessageTargetKey`；
- 标准备份格式不保存 Participant Delete 的删除者类型、逐设备回执或预期设备快照，因此恢复后不伪造删除者展示信息，也不恢复确认进度；如果产品要求完整恢复这些元数据，需要先扩展备份协议并让各平台共同实现；
- 墓碑优先级高于原消息和任何编辑版本；
- 新关联设备进行历史恢复时必须同步删除状态；
- 如果当前测试版本不支持历史同步，则在验收中明确标为不支持场景；
- 不承诺删除前生成且不含墓碑的旧备份自动知道后续删除。若必须覆盖这种旧备份，需要在恢复后从账号级持久删除账本重新同步，不能只依赖备份内的消息墓碑。

因此本方案默认的“备份恢复不复活”准确含义是：**从删除完成之后生成、且包含 remote-delete tombstone 的兼容备份恢复时，原内容不得复活。**这不等于完整备份 Participant Delete 的审计和设备确认账本。

## 11. 乱序与竞态处理

删除是终态，优先级高于编辑、反应、引用预览和重复原消息。

| 到达顺序 | 预期处理 |
| --- | --- |
| 原消息 → 删除 | 原消息转换为墓碑 |
| 删除 → 原消息 | pending tombstone 命中，正文不落盘 |
| 编辑 → 删除 | 最新编辑版本和原版本一起变为墓碑 |
| 删除 → 编辑 | 丢弃编辑内容，不得创建新可见版本 |
| 删除重复到达 | 幂等返回，不重复清理 |
| 反应 → 删除 | 清理反应或使其不可见 |
| 删除 → 反应 | 丢弃对墓碑的反应 |
| 引用回复 → 删除 | 保留回复本身，但清空/中性化引用快照 |
| 删除后兼容备份中的原消息/编辑 → 已导入的删除账本 | 删除账本胜出，原内容不得恢复 |

现有编辑处理已经拒绝编辑远程删除墓碑，可继续复用；新实现仍需补充“删除请求先到、原消息尚不存在”以及“恢复导入顺序变化”的覆盖测试。

处理所有编辑消息时，先检查其目标键是否已存在远程删除墓碑。不能只在删除接收路径处理，否则离线编辑仍可能把内容“复活”。

## 12. 附件、缓存与通知清理

### 12.1 附件

执行删除后：

- 删除 attachment reference；
- 清除已下载的加密附件和解密临时文件；
- 清除缩略图、视频首帧、音频波形和媒体预览；
- 清除媒体画廊索引；
- 取消尚未开始或正在进行的下载任务；
- 移除消息持有的附件密钥和摘要。

服务端 CDN 中的密文对象可能继续存在到正常过期时间。只要本地密钥与引用被清理，兼容客户端不能再通过该消息访问内容；这不等于能删除已另存到系统相册或其他 App 的副本。

### 12.2 引用回复

Signal 官方普通远程删除不会删除引用回复。为减少测试版本中的内容残留，本方案建议：

- 不删除整条回复消息；
- 把引用卡片中的原文、缩略图和附件名称替换为“原消息已删除”；
- 使用目标作者 + 时间戳 + thread 绑定查找引用；
- 不扫描和修改用户手工复制进回复正文的文字。

当前引用快照嵌在消息模型中，没有面向目标键的独立索引。`jack-patch` 先按当前会话和 `quotedMessage IS NOT NULL` 条件分页扫描，逐批中性化匹配引用并解绑引用缩略图；不会一次把全会话消息载入内存，也不会扫描其他会话。若超大群的引用消息规模使写事务时间不可接受，后续应再增加引用目标索引或可续跑后台任务。仅清理目标消息自身的 `quotedMessage` 字段不能覆盖其他消息中保存的引用快照。

### 12.3 通知

兼容客户端收到删除请求后应尝试：

- 移除该消息对应的待展示本地通知；
- 删除 Notification Service Extension 生成的缓存；
- 更新 App 内未读计数和会话摘要；
- 如果系统允许，移除已投递的本 App 通知。

iOS 已经展示给用户、被截图或被系统日志记录的通知不能保证撤回。

## 13. Signal-iOS 代码模块设计

Signal-iOS 文件结构会随分支变化，下列是建议模块及接入点。开发前先在实际 checkout 中检索现有实现，不按文档猜测类名。

### 13.1 源码定位

```bash
rg -n "AdminDelete|RemoteDelete|remotelyDeleteMessage" Signal SignalServiceKit
rg -n "targetSentTimestamp|targetAuthorAci" Signal SignalServiceKit
rg -n "deleteForEveryone|Delete for everyone" Signal SignalServiceKit
rg -n "MessageReceiver|InteractionFinder" SignalServiceKit
```

当前代码基线可重点参考：

```text
SignalServiceKit/Messages/Interactions/AdminDelete/AdminDeleteManager.swift
SignalServiceKit/Messages/MessageReceiver.swift
```

基于本文代码基线已经确认：

- `AdminDeleteManager.tryToAdminDeleteMessage` 已在查找和删除前验证管理员身份，可复用其 thread/作者/时间戳定位方式，不复用管理员策略；
- `TSMessage.remotelyDeleteMessage` 会处理全部编辑版本，但内置官方时间窗，需抽取已授权墓碑执行器；
- `TSMessage.updateWithRemotelyDeletedAndRemoveRenderableContent` 已清理通用正文、反应、附件引用和常见可渲染字段，并触发搜索索引更新；特殊消息子类仍需专项审计；
- `EditManagerImpl` 已拒绝编辑远程删除墓碑；
- `TransientOutgoingMessage` 继承默认 sent transcript 行为；
- `EarlyMessageManager` 的键只有作者和时间戳、默认一周清理，不适合作为本协议的稳定 pending store；
- Backup archiver 已支持普通和管理员删除墓碑，可作为 Participant Delete 备份扩展入口。

### 13.2 建议新增文件

```text
SignalServiceKit/Messages/Interactions/ParticipantDelete/
├── ParticipantDeleteConfiguration.swift
├── ParticipantDeleteCoordinator.swift
├── ParticipantDeleteValidator.swift
├── ParticipantDeleteManager.swift
├── OutgoingParticipantDeleteMessage.swift
├── ParticipantDeleteRequest.swift
├── ParticipantDeleteTombstone.swift
├── PendingParticipantDeleteRecord.swift
├── ParticipantDeleteDeviceReceipt.swift
├── ParticipantDeleteReceiptManager.swift
└── ParticipantDeleteCapabilityStore.swift
```

职责：

| 文件 | 职责 |
| --- | --- |
| Configuration | 功能开关、协议版本、无限历史消息策略 |
| Coordinator | 根据双人/群聊、作者和功能开关选择删除路径 |
| Validator | 无副作用的身份、当前群成员、thread 和目标校验，不检查消息年龄 |
| Manager | 事务内应用墓碑和 pending 逻辑 |
| OutgoingMessage | 构造和编码新控制消息 |
| Request | 保存 requestId、发送和回执聚合状态 |
| Tombstone | 保存独立于 interaction 生命周期的稳定目标键、删除者和防复活状态 |
| PendingRecord | 处理删除先于目标到达 |
| DeviceReceipt | 按 requestId、响应账号和 sourceDeviceId 保存执行回执 |
| ReceiptManager | 生成、发送和聚合执行回执 |
| CapabilityStore | 在服务端能力机制接通后记录账号能力；纯客户端原型中只记录观测结果，不声称掌握远端全部设备能力 |

### 13.3 需要修改的逻辑区域

1. **消息协议定义与生成代码**
   - 增加 `ParticipantDelete` 与回执结构；
   - 使用仓库现有脚本重新生成 Swift Protobuf 包装类型；
   - 不手工编辑自动生成文件。

2. **消息发送管线**
   - 增加 outgoing control message；
   - 对端投递并复用现有 sent transcript 同步本账号关联设备；
   - 重试时保持同一 `requestId`。

3. **消息接收管线**
   - 在 `MessageReceiver` 的 data message 分发中识别新字段；
   - 从 envelope 获取认证请求者；
   - 把当前 thread 显式传入 validator；
   - 非当前成员、错误 thread 或错误目标的请求只记匿名化诊断，不产生删除副作用。

4. **Interaction/消息模型**
   - 增加 participant-deleted 状态或原因；
   - 支持删除者展示；
   - 删除状态覆盖编辑状态。

5. **数据库迁移**
   - 新建 request/tombstone/pending 表及各自唯一索引；
   - tombstone 不以 interaction 外键级联删除作为生命周期；
   - 稳定 conversation key 与本地 thread 加速字段分开保存；
   - 保证重复迁移和降级构建不会破坏原消息数据库；
   - 测试从旧版本升级。

6. **会话 UI**
   - 对收到的消息增加操作项；
   - 增加确认框、发送状态和墓碑样式；
   - 适配多选删除、双人/群聊和兼容性混合状态。

7. **索引和缓存**
   - 搜索、媒体库、会话摘要、通知、引用快照执行清理；
   - 若要求清理其他消息内的既有引用快照，增加引用目标索引或可续跑后台任务；
   - App 启动时为未完成的物理清理任务重试。

8. **本地化**
   - 新增操作、确认、墓碑、失败、兼容性和重试文案；
   - 覆盖简体中文和项目要求的其他语言。

### 13.4 不通过绕过管理员判断实现

可以复用以下底层、无权限语义的能力：

- 精确消息查找；
- 把消息转换为远程删除墓碑；
- 清理可渲染内容；
- 附件与索引清理。

但不要让 `ParticipantDeleteManager` 伪造管理员请求，也不要直接删除 `AdminDeleteManager` 的管理员检查。当前 `TSMessage.remotelyDeleteMessage` 内置官方时间窗，因此也不能通过传入极大时间值来复用。正确方式是为“任意当前群成员删除”建立独立入口，再把共同的“已完成会话、成员和时间策略校验后的删除执行器”抽成内部组件，例如：

```swift
protocol AuthorizedRemoteDeleteApplying {
    func apply(
        target: TSMessage,
        authorization: ValidatedRemoteDeleteAuthorization,
        tx: DBWriteTransaction
    ) throws
}
```

普通作者删除、官方语义下的群管理员删除、双人会话成员删除，以及本测试版本的任意当前群成员删除，分别生成不同的 `ValidatedRemoteDeleteAuthorization`，再调用共同执行器。群成员路径只要求 `isFullMember`，不要求 `isFullMemberAndAdministrator`。

## 14. 服务端方案

### 14.1 内部测试：优先不改服务端

如果新字段位于端到端加密的内容消息中，Signal 服务端原则上只负责转发密文。内部测试可以先使用现有投递管线完成两个修改版 iOS 客户端之间的验证。

需要实际验证：

- 当前服务端是否会原样转发包含新字段的内容；
- 多设备发送是否覆盖所有目标设备；
- 未知客户端是否安全忽略消息；
- 离线队列保留时间是否满足 pending tombstone 策略；
- 回执能否作为发给请求者账号的一对一加密控制消息发送并正确同步；
- 当前服务端是否能提供发送时的预期设备集合。若不能，客户端不得显示“全部兼容设备已确认”；
- Profile/Account Attributes 是否允许发布 `participantDeleteV1` 能力位；若不修改服务端，内部原型采用未知能力降级语义。

### 14.2 稳定产品：建议使用自有兼容基础设施

如果准备长期维护或覆盖 iOS、Android、Desktop，建议在自有环境中管理：

- 协议版本与最低客户端版本；
- 设备能力注册；
- 功能灰度开关；
- 消息队列和离线保留策略；
- 回执聚合状态；
- 发送时的预期设备快照及设备新增、解绑、长期不活跃规则；
- 跨平台发布节奏。

服务端仍不需要拥有消息明文，也不负责判断管理员身份。客户端只根据端到端认证身份和当前会话成员状态执行本测试规则。

## 15. 调试一致性与误删隔离

本方案不增加管理员审批、成员同意或额外授权机制。所有当前群成员都具有删除本群任意消息的能力。本节只处理会影响调试正确性的错误输入和状态冲突。

### 15.1 需要避免的调试故障

需要避免：

- 删除请求跨 thread 命中另一会话的消息；
- 重复投递导致重复删除或数据库异常；
- 已经离群的设备继续把请求当作当前群请求处理；
- 未来目标时间戳提前删除随后到达的无关消息；
- 合法成员通过大量不存在目标和随机 requestId 耗尽 pending 表；
- 删除先到、原消息后到导致内容重新出现；
- 编辑或备份恢复使已删内容重新出现；
- 先执行删除、后检查 thread，且异常没有回滚；
- 日志记录正文、附件路径或完整 ACI。

### 15.2 最小正确性约束

- 远端请求者只取 `envelope.sourceAci`；本账号 sent transcript 和本地立即执行从受信执行上下文取得本地 ACI；
- 本账号 sent transcript、本地立即执行与远端 envelope 使用不同的 origin 校验；
- 目标查找必须包含 thread、作者和发送时间戳；
- 双人会话 targetAuthor 只能是本地账号或对方账号；
- 群聊只检查请求者是当前 `full member`，明确不检查管理员身份；
- 所有会话与目标检查在破坏性操作之前；
- 网络接收时目标时间戳不能晚于可信服务端时间；本地立即执行要求目标已存在并精确匹配；调试版不限制历史消息年龄；
- `requestId` 唯一索引与幂等处理；
- pending tombstone 必须绑定稳定 conversation key，并设置容量上限和过期策略；
- 墓碑优先级高于原消息、编辑和备份；
- 非法请求只记录错误类别，不记录消息正文；
- 不增加管理员、所有者或目标作者同意步骤。

### 15.3 可审计日志

测试构建可记录：

```text
requestIdHash
threadIdHash
targetTimestamp
protocolVersion
validationResult
applyResult
delivery/receipt state
```

不要记录：

- 消息正文；
- 附件密钥；
- 完整手机号；
- 完整 ACI；
- 解密附件路径。

## 16. 功能开关与发布策略

新增双层开关：

```swift
BuildFlags.ParticipantDelete.compileEnabled
RemoteConfig.ParticipantDelete.receiveEnabled
RemoteConfig.ParticipantDelete.sendEnabled
```

建议顺序：

1. 先发布只能接收、默认关闭发送的版本；
2. 确认两端接收和墓碑逻辑稳定；
3. 对测试账号开启发送 UI；
4. 覆盖关联设备和离线场景；
5. 最后考虑扩大范围。

即使关闭 `sendEnabled`，已经发布的版本也应继续识别此前格式正确且来自当前会话成员的删除请求，避免旧消息因开关变化复活。紧急情况下可关闭接收，但这会导致跨设备状态不一致。

## 17. 测试方案

### 17.1 单元测试

- protobuf 正常编码、解码和未知版本；
- 请求者身份只来自 envelope；
- 本地立即执行、远端 envelope 和本账号 sent transcript 三种 origin；
- 双人会话双方关系校验；
- 双人会话拒绝第三方 targetAuthor；
- Group V2 当前正式成员校验；
- 普通群成员与管理员具有相同删除结果；
- 目标 author/thread/timestamp 精确匹配；
- 数天、数月或更早的历史消息不因年龄被拒绝；
- 未来时间戳与溢出值；
- 请求重复投递幂等；
- 不同 requestId 指向同一目标时合并为已执行；
- 非法请求不产生数据库副作用；
- 先删后到 pending tombstone；
- pending tombstone 的会话/请求者/全局容量上限和过期清理；
- 删除覆盖编辑和反应；
- 支持的普通文本、附件、联系人、贴纸、支付、礼物、投票和一次性查看类型逐类验证；不支持的系统 interaction 不显示入口；
- 墓碑备份与恢复。

### 17.2 集成测试矩阵

| 场景 | 客户端组合 | 预期 |
| --- | --- | --- |
| 在线双人会话 | A 新版、B 新版 | B 可删除 A 的消息，双方变墓碑 |
| 对方离线 | A 新版在线、B 新版离线 | B 上线后执行，不复活 |
| 在线三人群聊 | A/B/C 均为新版，C 是普通成员 | C 可删除 A 或 B 的消息，A/B/C 均变墓碑 |
| 群管理员删除 | A/B/C 均为新版，管理员 A 发起 | 与普通成员相同，走 Participant Delete V1 即可 |
| 群成员已离开 | C 已退出群后再次发送旧请求 | 当前成员检查失败，不修改群消息 |
| 目标作者已离群 | C 当前在群，删除已离群 A 的历史消息 | 允许删除，所有兼容设备变墓碑 |
| 群成员离线 | A/B 在线、C 离线 | C 上线后处理群删除请求，不恢复内容 |
| 删除先到 | 新版设备乱序收包 | 后到原消息直接变墓碑 |
| 请求重复 | 新版设备收到相同 requestId | 仅执行一次 |
| 成员有关联设备 | 主设备和关联设备均为新版 | sent transcript 使该账号全部已投递兼容设备同步墓碑 |
| 群中存在旧版 | 部分新版、部分官方版/旧版 | 新版执行；旧版可能保留；UI 显示未完全确认 |
| 很早的历史消息 | 新版设备，调试配置不限制年龄 | 正常删除 |
| 错误 targetAuthor | 构造错误测试包 | 不命中无关消息 |
| 跨群相同时间戳 | 两个群存在相同作者和时间戳 | 只能删除请求所在群的目标 |
| 删除后编辑到达 | 新版设备 | 编辑被丢弃，墓碑保持 |
| 删除后恢复兼容备份 | 备份生成于删除完成之后 | 先导入删除账本，原内容不复活 |
| 恢复删除前旧备份 | 备份不含墓碑且无账号级删除账本 | 明确不保证；不得把该场景记录为已支持 |
| 回执但设备集合未知 | 纯客户端部署 | 只显示已有设备确认，不显示全部设备完成 |

### 17.3 数据残留检查

删除后检查：

- 主消息表没有正文；
- FTS/搜索结果没有目标文本；
- attachment reference 已移除；
- 沙盒附件、缩略图和临时解密文件已清理；
- 媒体画廊不再展示；
- 会话列表摘要不显示原文；
- 引用卡片不显示原文或缩略图；
- 通知缓存不再包含原内容；
- 调试日志不包含正文和密钥。

## 18. 验收标准

### 18.1 必须满足

- B 能在双人会话中对 A 发送的任意历史消息选择“从双方设备删除”；
- A、B 的所有实际收到请求的兼容在线设备把目标转换为墓碑；
- 群聊任意当前正式成员都能删除本群任意作者的任意历史消息，不要求管理员身份；
- 群聊中所有实际收到请求的兼容在线设备都把目标转换为墓碑；
- 在服务端离线保留窗口内上线的兼容设备执行删除；发送端断网时本地发送任务使用同一 requestId 重试；
- 删除请求不能跨双人会话、跨群或跨作者命中；
- 已离群设备、错误格式和错误目标请求不修改任何消息或附件；
- 重复请求幂等；
- 删除后到达的原消息、编辑和反应不能恢复内容；
- 消息正文、附件、缩略图、搜索索引和引用预览按本方案清理；
- UI 不把服务端“已投递”误显示为“所有设备已删除”；
- 不知道预期设备集合时，UI 不显示“全部兼容设备已确认”；
- 群聊普通成员和管理员的删除入口、协议路径与执行结果一致。

### 18.2 明确不保证

- 官方或旧版客户端执行自定义删除；
- 删除对方已经截图、复制、转发、导出或另存的内容；
- 撤回已经被用户看到的系统通知；
- 从第三方备份、系统相册或其他 App 中删除副本；
- 仅凭删除后产生的本地墓碑阻止删除前旧备份恢复原内容；除非另行实现账号级持久删除账本和恢复后同步；
- 对恶意修改、拒绝执行协议的客户端提供强制擦除证明。

## 19. 分阶段开发计划

### 阶段一：现有实现梳理

- 锁定 Signal-iOS commit；
- 找出现有 Remote Delete、Admin Delete、MessageReceiver 和墓碑清理链路；
- 写出现有作者删除与管理员删除的调用图；
- 确定 protobuf 源文件和生成命令。

交付物：源码定位清单和现有链路时序图。

### 阶段二：协议与数据库

- 新增 `ParticipantDeleteV1` 和回执；
- 新增 request、稳定 tombstone、pending、回执聚合记录及唯一索引和迁移；
- 实现无副作用的会话、当前成员和目标 validator；
- 实现稳定 target key、pending tombstone、配额和过期策略；
- 抽取不带权限和时间策略的已授权墓碑执行器。

交付物：协议测试、迁移测试和成员/目标校验单测。

### 阶段三：iOS 收发闭环

- 接入 outgoing message；
- 接入 MessageReceiver；
- 复用完成会话与成员校验后的删除执行器；
- 完成两台在线 iPhone 的双人删除闭环；
- 完成至少三台在线 iPhone 的群聊普通成员删除闭环。

交付物：两端在线演示包。

### 阶段四：UI 与内容清理

- 增加长按菜单、确认页、墓碑和状态；
- 清理附件、索引、通知和引用预览；
- 完成本地化。

交付物：可供测试人员使用的完整 iOS 构建。

### 阶段五：多设备与离线竞态

- 复用 sent transcript 完成自己的关联设备同步；
- 双人对方及群聊成员的一对一设备回执；
- 删除先到、原消息后到；
- 编辑/反应/备份恢复防复活；
- 兼容性与失败提示；
- 仅在可获得预期设备集合时实现“全部预期设备已确认”，否则保持部分确认语义。

交付物：集成测试报告与已知限制清单。

### 阶段六：跨平台

若测试范围包含 Android 或 Desktop，必须在对应客户端实现同一协议、成员/目标校验和墓碑语义。只有 iOS 改造无法满足跨平台“所有设备删除”。

## 20. 工作量粗估

以下按熟悉 Signal-iOS 架构的一名开发人员估算，不含上游代码大幅变化带来的适配：

| 范围 | 粗略工作量 |
| --- | --- |
| 双人两台 + 群聊三台修改版 iPhone 在线原型 | 7–12 个开发日 |
| iOS 完整版：数据库、离线、多设备、缓存清理、测试 | 3–6 周 |
| 可证明的“全部预期设备确认”：设备快照、逐设备回执及服务端配合 | 需在服务端接口明确后单独评估 |
| 删除前旧备份防复活：账号级持久删除账本及恢复后同步 | 需单独评估，不包含在纯 iOS 3–6 周内 |
| iOS + Android + Desktop 一致实现 | 2–3 个月以上 |
| 自有服务端能力管理、灰度和跨平台长期维护 | 需单独评估 |

## 21. 开发决策摘要

最终建议如下：

1. 双人会话和 Group V2 群聊新增 `ParticipantDeleteV1`，不篡改普通 Remote Delete 或 Admin Delete 语义；
2. 远端请求者身份来自加密 envelope，本账号同步和本地立即执行使用显式 origin；目标显式包含作者 ACI 和时间戳；
3. 目标定位必须绑定稳定 conversation key、当前本地 thread、作者和时间戳；
4. 会话、当前成员关系和目标匹配检查先于任何内容删除；
5. 把现有远程删除实现拆成策略校验和无权限语义的已授权墓碑执行器；
6. 使用独立于 interaction 生命周期的稳定墓碑、请求记录和短期 pending tombstone 防止内容复活；
7. 优先复用现有 sent transcript 同步本账号关联设备，不默认新增专用同步协议；
8. 增加按账号和 sourceDeviceId 聚合的执行回执，但在未知预期设备集合时只显示部分确认，不声称全部设备完成；
9. 删除后生成的兼容备份必须保存稳定删除账本；删除前旧备份不在默认保证范围；
10. 引用回复保留回复本身；若要求清空全部既有引用快照，必须增加引用目标索引或可续跑后台任务；
11. 群聊任意当前正式成员均可删除任何成员的消息，不检查管理员身份，也不限制已存在历史消息的年龄；
12. 只有所有设备安装兼容客户端且实际收到请求时，才能接近“所有手机都删除”的用户体验。

## 22. 参考资料

- [Signal 官方：Delete for everyone](https://support.signal.org/hc/en-us/articles/360050426432-Delete-for-everyone)
- [Signal 官方：Manage a group / Admin remote delete](https://support.signal.org/hc/en-us/articles/360050427692-Manage-a-group)
- [Signal-iOS 官方仓库](https://github.com/signalapp/Signal-iOS)
- [Signal-iOS：AdminDeleteManager.swift](https://github.com/signalapp/Signal-iOS/blob/f9a20dbafa3cd896820c3da4d75a10b0a5a94969/SignalServiceKit/Messages/Interactions/AdminDelete/AdminDeleteManager.swift)
- [Signal-iOS 管理员删除鉴权修复提交](https://github.com/signalapp/Signal-iOS/commit/ee3f6b545326c884b53a228b13266faf375f5c93)
- [GitHub Security Lab：Signal-iOS 未授权消息删除分析](https://securitylab.github.com/advisories/GHSL-2026-095_iOS_SignalApp/)
- [Signal-Android：编辑与远程删除乱序问题](https://github.com/signalapp/Signal-Android/issues/14329)
- [libsignal 官方仓库](https://github.com/signalapp/libsignal)

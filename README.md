# BitGuard Vesting Vault - 设计细节

---
ETH Sepolia addr: 0x3EE2d0f077555079d76Ee1910EBb347C0c266575
---

## 1. 设计理念 & 安全模型

### 核心理念
BitGuard Vesting Vault 以 **“安全优先”** 为设计原则，比起功能复杂性，更注重资金安全与归属时间表（Vesting Schedule）的完整性。主要目标是提供一个稳健、可撤销的归属机制，适用于项目上线、管理层激励等场景。

### 安全模型
* **所有者 / 用户分离：** 权限清晰且严格区分。只有 `Owner`（管理员）可以创建或撤销归属计划；受益人（用户）只能领取属于其已归属的代币。
* **拉取式(Pull) 而非推送式(Push)：** `claim` 函数采用拉取模式，代币不会自动发放，用户必须主动领取。这防止了可重入攻击，也避免用户存在大量计划时的 Gas 上限问题。
* **Checks-Effects-Interactions 模式：** 所有状态更新（如 `releasedAmount` 或 `revoked` 状态）都在与外部交互（代币转账）**之前**完成，防止可重入攻击。
* **SafeERC20：** 使用 OpenZeppelin 的 `SafeERC20` 库，确保兼容未返回布尔值的非标准 ERC20。

---

## 2. 归属数学模型

### 线性归属公式
归属逻辑遵循严格的线性释放公式：

$$
VestedAmount = TotalAmount \times \frac{CurrentTime - StartTime}{Duration}
$$

### 精度控制
Solidity 不支持浮点数，为避免精度损失，我们采取以下策略：

1. **先乘后除：** 先将 `TotalAmount` 与 `TimePassed` 相乘，再除以 `Duration`。
    ```solidity
    (schedule.totalAmount * timePassed) / schedule.duration
    ```
2. **最小单位计算：** 所有运算以代币最小单位（wei）进行。即使归属持续时间很长，四舍五入误差最多 1 wei，可忽略不计。

### Cliff 悬崖期
实现了 cliff 机制：在 `CurrentTime < StartTime + Cliff` 时，`VestedAmount = 0`。一旦过了 cliff 时间点，线性归属立即生效，仿佛从 `StartTime` 起开始线性计算。

---

## 3. 撤销机制

### 为什么需要可撤销？
在现实中（如员工激励），公司需要在员工离职时收回 **未归属** 的代币。

### 实现细节
当调用 `revokeSchedule` 时：

1. **计算已归属数量：** 合约根据当前区块时间计算已归属代币。
2. **计算应退还数量：** 立即计算 *未归属* 的代币：`TotalAmount - VestedAmount`。
3. **更新状态：**
    * 设置 `revoked = true`
    * 将 `totalAmount` 更新为 `VestedAmount` —— 通过“封顶”避免未来继续归属
4. **退回代币：** 将未归属金额转回 Owner

该机制确保受益人获得截止撤销时的应得部分，而剩余资金安全返还给所有者。

---

## 4. 测试策略

**核心不变量：偿付能力（Solvency）**
Vault 最关键的性质是 **永不透支**：

> Vault 必须始终持有足够的代币来覆盖所有尚未领取的已归属金额。

在不变量测试 `invariant_Solvency` 中，验证：
TokenBalance(Vault) == Sum(UnclaimedAmounts)

该验证确保无论创建、领取、撤销的顺序和次数如何变化，资金流数学始终自洽，Vault 永不进入资不抵债的状态。

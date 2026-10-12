# 共享模型定价

macOS 从 `Resources/model-pricing.json` 读取模型价格，打包为本地资源；运行时不请求报价服务。目录和共同算例独立于 Swift，可供 Windows 等其他实现复用。Windows 运行时接入另行交付。金额是本机 Token 按 API 价格折算的估算，不是订阅账单。

单位为美元 / 百万 Token。新增模型或价格变动只更新该文件；模型名及显式别名匹配不区分大小写，允许日期快照后缀，未知变体不能继承一个看似相近的专属价格。

2026-10-11 核对的 GPT-6 价格：

| 模型 | 输入 | 缓存读取 | 缓存写入 | 输出 |
| --- | ---: | ---: | ---: | ---: |
| GPT-6.1 Sol | 2 | 0.10 | 2.50 | 10 |
| GPT-6 Sol | 2 | 0.20 | 2.50 | 10 |
| GPT-6 Astra | 10 | 1 | 12.50 | 50 |
| GPT-6 Luna | 0.10 | 0.01 | 0.125 | 0.50 |

来源：[Sol 6.1](https://developers.openai.com/api/docs/models/gpt-6.1-sol)、[Sol 6](https://developers.openai.com/api/docs/models/gpt-6-sol)、[Astra](https://developers.openai.com/api/docs/models/gpt-6-astra)、[Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)、[服务层级价格表](https://developers.openai.com/api/docs/pricing)。[GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol) 本次同步官方现行优惠价：4 / 0.4 / 5 / 20，官方保证至少到 2026-11-21；本地不会到期自动猜价。

GPT-6 请求输入超过 272,000 时，整次输入及缓存费用乘 2，输出乘 1.5。Fast / priority 为标准价格的 2 倍，Batch / Flex 为 0.5 倍；GPT-6.1 Sol 与 Astra 的 Ultrafast 为 6 倍。这些倍率与长上下文叠加。只使用日志记录的服务层级；未记录则按标准价。推理 Token 已包含在输出中，不重复收费。

没有专属条目的模型按表内 GPT-5.5 参考价折算，并明确标注参考估算。未识别的服务层级按已知标准基准参考折算，不能冒充该层级的专属价格。Claude 的旧家族费率集中在共享表，并标记为参考价；本次没有重新核实各 Claude 版本的官方费率。区域处理、工具费等本地日志没有足够事实的项目不自动补收，因此估算不代表完整实际 API 账单。

价格表字节摘要参与 macOS 费用投影身份，目录变化后重新生成派生费用。解析版本提升后，旧解析记录重新读取以补齐计费条件；真实日志不修改。

共同算例在 `Resources/model-pricing-vectors.json`，包括输入、预期美元金额和参考标记。macOS 使用 `make test-model-pricing`，或在构建后运行 `build/codexU.app/Contents/MacOS/codexU --self-test-model-pricing`。Mac CI 构建后执行相同自测；其他平台可用该算例文件核对自身实现。

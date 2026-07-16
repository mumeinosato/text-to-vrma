# Third-Party Notices

## VRoid AvatarSample

This repository includes VRoid sample models (`public/models/AvatarSample_VRM1.0.vrm`,
`public/models/AvatarSample_VRM0.0.vrm`) provided by pixiv Inc.

The sample models are **not** licensed under the MIT License that applies to the
Text-To-VRMA source code. Use of the sample models is governed by the following terms:

AvatarSample A–Z Terms of Use
<https://vroid.pixiv.help/hc/ja/articles/4402394424089-AvatarSample-A-Z>

The sample models are included solely for demonstration and testing purposes.
Copyright and all other rights relating to the sample models belong to their
respective rights holders.

---

本リポジトリには、ピクシブ株式会社が提供する VRoid サンプルモデル
(`public/models/AvatarSample_VRM1.0.vrm`, `public/models/AvatarSample_VRM0.0.vrm`)
が含まれています。

サンプルモデルは、Text-To-VRMA のソースコードに適用される MIT License の対象外です。
サンプルモデルの利用には「AvatarSample A〜Z」の利用条件が適用されます:

<https://vroid.pixiv.help/hc/ja/articles/4402394424089-AvatarSample-A-Z>

サンプルモデルはデモおよび動作確認の目的でのみ同梱されています。
サンプルモデルに関する著作権およびその他の権利は、それぞれの権利者に帰属します。

---

## ARDY ローカルエンジン (tools/ardy-engine) が利用する外部モデル

ARDYローカルエンジン機能は、以下のモデル・ソフトウェアを利用します。
モデル重みは本リポジトリに同梱されず、セットアップ時に各配布元 (Hugging Face) から取得されます。

- **NVIDIA ARDY** (nv-tlabs/ardy) — コード: Apache License 2.0 /
  モデル重み: NVIDIA Open Model Agreement
  <https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-agreement/>
- **Meta Llama 3 (Meta-Llama-3-8B-Instruct)** — Meta Llama 3 Community License
  <https://llama.meta.com/llama3/license>
  本機能は Meta Llama 3 を利用して構築されています。**Built with Meta Llama 3**
  "Meta Llama 3 is licensed under the Meta Llama 3 Community License,
  Copyright © Meta Platforms, Inc. All Rights Reserved."
- **LLM2Vec** (McGill-NLP/LLM2Vec-Meta-Llama-3-8B-Instruct-mntp / -supervised) — MIT License
- **FuguMT** (staka/fugumt-ja-en、日本語→英語翻訳) — CC BY-SA 4.0

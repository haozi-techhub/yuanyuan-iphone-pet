# 圆圆离线音色来源

模型来自 [Kokoro-82M v1.1 zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh)，经 sherpa-onnx 转换成 [INT8 ONNX 模型包](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2)。模型与 sherpa-onnx 运行库使用 Apache License 2.0，许可证见本目录。

采用普通话女声 [zf_001](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/blob/main/samples/HEARME_zf_001.wav)。它在原始音色文件中是索引 3。内置的 `voices.bin` 仅保留这个音色的 522,240 字节原始浮点数据，在 App 内使用索引 0。`model.int8.onnx` 的计算图保持原样，仅更新了 `n_speakers`、`speaker_names`、`id2speaker`、`speaker2id` 四项元数据。

| 文件 | SHA-256 |
| --- | --- |
| 原始 `kokoro-int8-multi-lang-v1_1.tar.bz2` | `259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c` |
| 原始 `model.int8.onnx` | `05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222` |
| 原始 `voices.bin` | `e64a5a581d8c2a350d848f51c3121657cd83aa07ed6109172177345874a7244c` |
| 内置 `model.int8.onnx` | `6ca5279c4476150ab46614a5cf33ec7b67c1a2b15223da6ca99c4656af16557f` |
| 内置 `voices.bin` | `0a89ec12bb93fb9c74077924daf02568baad64e1f869389f5aaee01a386035f8` |

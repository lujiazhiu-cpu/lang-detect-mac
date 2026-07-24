//
//  FastTextBridge.h — Objective-C++ 封装，暴露给 Swift 调用的纯 C 接口
//  （任务B 方式1：编译 fastText C++ 静态库，Swift 经 bridging header 调用，性能最佳，无进程开销）
//
//  用法见 FASTTEXT_INTEGRATION.md。所有函数线程安全（内部单例 + 互斥锁）。
//
#ifndef FastTextBridge_h
#define FastTextBridge_h

#ifdef __cplusplus
extern "C" {
#endif

// 加载模型（.bin 或 .ftz）。成功返回 1，失败返回 0。可重复调用（幂等）。
int ftbridge_load_model(const char *model_path);

// 是否已成功加载模型
int ftbridge_is_ready(void);

// 预测单行文本的 top-1 语种。
//   text        : UTF-8 文本
//   out_label   : 输出缓冲区，写入语种码（如 "it"，已去掉 __label__ 前缀）
//   label_cap   : out_label 缓冲区容量
//   out_prob    : 输出概率(0~1)
// 返回 1 成功，0 失败（未加载/空输入/异常）。
int ftbridge_predict(const char *text, char *out_label, int label_cap, float *out_prob);

#ifdef __cplusplus
}
#endif

#endif /* FastTextBridge_h */

//
//  FastTextBridge.mm — Objective-C++ 实现，桥接 fastText 官方 C++ API
//  编译需链接 fastText 静态库(libfasttext.a) 与其头文件（见 CMakeLists.txt / 集成文档）。
//
#import "FastTextBridge.h"

#include <fasttext.h>   // 来自 facebookresearch/fastText 的 src/fasttext.h（include 根设为 src/）

#include <string>
#include <sstream>
#include <vector>
#include <mutex>
#include <cmath>
#include <cstring>
#include <memory>

static std::unique_ptr<fasttext::FastText> g_ft;
static std::mutex g_mtx;

extern "C" int ftbridge_load_model(const char *model_path) {
    if (model_path == nullptr) return 0;
    std::lock_guard<std::mutex> lock(g_mtx);
    try {
        auto ft = std::make_unique<fasttext::FastText>();
        ft->loadModel(std::string(model_path));
        g_ft = std::move(ft);
        return 1;
    } catch (const std::exception &e) {
        g_ft.reset();
        return 0;
    } catch (...) {
        g_ft.reset();
        return 0;
    }
}

extern "C" int ftbridge_is_ready(void) {
    std::lock_guard<std::mutex> lock(g_mtx);
    return g_ft ? 1 : 0;
}

extern "C" int ftbridge_predict(const char *text, char *out_label, int label_cap, float *out_prob) {
    if (text == nullptr || out_label == nullptr || label_cap <= 0) return 0;
    std::lock_guard<std::mutex> lock(g_mtx);
    if (!g_ft) return 0;
    try {
        // fastText 按行读取，换行会截断样本，这里折叠为空格
        std::string s(text);
        for (auto &c : s) { if (c == '\n' || c == '\r') c = ' '; }
        std::istringstream iss(s);

        std::vector<std::pair<fasttext::real, std::string>> preds;
        // k=1 取 top-1；threshold=0.0 不过滤
        g_ft->predictLine(iss, preds, 1, 0.0f);
        if (preds.empty()) return 0;

        // preds[i].first 为 log 概率 → exp 还原为 0~1 概率
        float prob = std::exp(preds[0].first);
        std::string label = preds[0].second;           // 形如 "__label__it"
        const std::string prefix = "__label__";
        if (label.rfind(prefix, 0) == 0) label = label.substr(prefix.size());

        std::strncpy(out_label, label.c_str(), (size_t)label_cap - 1);
        out_label[label_cap - 1] = '\0';
        if (out_prob) *out_prob = prob;
        return 1;
    } catch (...) {
        return 0;
    }
}

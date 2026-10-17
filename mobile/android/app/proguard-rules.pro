# HealthLink 混淆规则（当前 release 未开启 minifyEnabled，此文件为占位）
# 若日后开启混淆，SensorPro SDK 通过反射调用，必须保留其类名：
-keep class com.huawei.hiresearch.** { *; }
-keep class com.healthlink.collector.protocol.** { *; }
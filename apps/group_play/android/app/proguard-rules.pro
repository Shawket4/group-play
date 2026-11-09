# Shizuku instantiates the user service by class name in the shell process; R8 can't see that.
-keep class com.shawket.groupplay.ShellCaptureService { *; }

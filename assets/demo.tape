Output "assets/demo.gif"

Set Shell "zsh"
Set FontSize 14
Set Width 860
Set Height 520
Set WindowBar Colorful
Set Theme "TokyoNight"
Set Padding 20
Set TypingSpeed 40ms

# 1. Run dush with grand total
Type "./dush -c src bench tests"
Sleep 300ms
Enter
Sleep 1.5s

# 2. Exact format parity with du -sh
Type "du -sh src bench tests"
Sleep 300ms
Enter
Sleep 1.5s

# 3. Direct performance comparison
Type "hyperfine --shell=none --warmup 3 --runs 10 './dush .' 'du -sh .'"
Sleep 300ms
Enter
Sleep 3.5s

Sleep 3.5s

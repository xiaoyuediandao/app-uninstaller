property myIcon : missing value

on ensureIcon()
	if myIcon is missing value then
		try
			set myIcon to (path to resource "droplet.icns" in bundle (path to me))
		on error
			set myIcon to caution
		end try
	end if
	return myIcon
end ensureIcon

on run
	set ic to ensureIcon()
	display dialog "彻底卸载  v1.0

把要卸载的 .app 拖到我身上，我会连根拔起：

• 应用本体 + 全部残留文件（约 30 个位置）
• 驻留进程、启动项/守护进程
• 钥匙串条目、pkg 安装收据、系统扩展

文件进废纸篓（可恢复）；名称相近但可能属于其他软件的文件只提示、绝不删除。

项目源码: ~/Code/app-uninstaller" with title "彻底卸载" buttons {"好"} default button 1 with icon ic
end run

on open droppedItems
	set ic to ensureIcon()
	repeat with anItem in droppedItems
		set p to POSIX path of anItem
		if p ends with ".app" or p ends with ".app/" then
			try
				with timeout of 3600 seconds
					do shell script "/bin/zsh /Users/bytedance/bin/app-uninstaller.sh --gui " & quoted form of p
				end timeout
			on error errMsg number errNum
				-- -128=用户取消; 2=脚本已自行弹窗说明
				if errNum is not -128 and errNum is not 2 then
					display dialog "卸载出错: " & errMsg buttons {"好"} default button 1 with icon stop
				end if
			end try
		else
			display dialog "只能卸载 .app 应用，这个不是: " & p buttons {"好"} default button 1 with icon caution
		end if
	end repeat
end open

local function clear_cache()
    local dir = SHGetFolderPath('LOCAL_APPDATA') .. 'Gas Powered Games\\Supreme Commander Forged Alliance\\cache\\'
    LOG('Clearing cached shader files in: ' .. dir)
    for _,file in io.dir(dir .. '**') do
        if string.find(file, 'mesh') then
            os.remove(dir .. file)
        end
    end
end

clear_cache()

dev_path = 'E:\\GITS\\fa'
dev_pathnomads = 'E:\\GITS\\nomads'
-- this imports a path file that is written by Forged Alliance Forever right before it starts the game.
dofile(InitFileDir .. '\\..\\fa_path.lua')
path = {}
local function mount_dir(dir, mountpoint)
    table.insert(path, { dir = dir, mountpoint = mountpoint } )
end
local function mount_contents(dir, mountpoint)
    LOG('checking ' .. dir)
    for _,entry in io.dir(dir .. '\\*') do
        if entry != '.' and entry != '..' then
            local mp = string.lower(entry)
            mp = string.gsub(mp, '[.]scd$', '')
            mp = string.gsub(mp, '[.]zip$', '')
            mount_dir(dir .. '\\' .. entry, mountpoint .. '/' .. mp)
        end
    end
end
-- these are the classic supcom directories. They don't work with accents or other foreign characters in usernames
mount_contents(SHGetFolderPath('PERSONAL') .. 'My Games\\Gas Powered Games\\Supreme Commander Forged Alliance\\mods', '/mods')
mount_contents(SHGetFolderPath('PERSONAL') .. 'My Games\\Gas Powered Games\\Supreme Commander Forged Alliance\\maps', '/maps')
-- these are the local FAF directories. The My Games ones are only there for people with usernames that don't work in the uppder ones.
mount_contents(InitFileDir .. '\\..\\user\\My Games\\Gas Powered Games\\Supreme Commander Forged Alliance\\mods', '/mods')
mount_contents(InitFileDir .. '\\..\\user\\My Games\\Gas Powered Games\\Supreme Commander Forged Alliance\\maps', '/maps')
mount_dir(dev_path, '/')
mount_dir(dev_pathnomads, '/')
mount_dir(dev_pathnomads .. '\\movies', '/')

-- these are using the newly generated path from the dofile() statement at the beginning of this script
mount_dir(fa_path .. '\\gamedata\\*.scd', '/')
mount_dir(fa_path, '/')
hook = {
    '/schook',
    '/nomadhook',
    '/sounds',
    '/movies'
}
protocols = {
    'http',
    'https',
    'mailto',
    'ventrilo',
    'teamspeak',
    'daap',
    'im',
}

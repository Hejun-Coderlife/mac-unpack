# 把几轨 Apple Loops 叠成一段试听：python3 tools/loopmix.py 输出.mp3 "轨名@音量" ...
# （轨名 = /Library/Audio/Apple Loops/Apple 下的文件名，不带 .caf；同一组的几轨调和速度本来就对得上）
import subprocess, sys, glob
out, specs = sys.argv[1], sys.argv[2:]
root = '/Library/Audio/Apple Loops/Apple'
args, chains = [], []
for i, s in enumerate(specs):
    name, vol = s.rsplit('@', 1)
    path = glob.glob(f'{root}/**/{glob.escape(name)}.caf', recursive=True)[0]
    args += ['-stream_loop', '3', '-i', path]
    chains.append(f'[{i}:a]volume={vol}[a{i}]')
mix = ''.join(f'[a{i}]' for i in range(len(specs)))
fl = ';'.join(chains) + f';{mix}amix=inputs={len(specs)}:normalize=0,atrim=0:26,afade=t=in:d=0.5,afade=t=out:st=23:d=3,loudnorm=I=-16[o]'
subprocess.run(['ffmpeg', '-v', 'error', '-y', *args, '-filter_complex', fl, '-map', '[o]', '-ar', '48000', out], check=True)
print('ok', out)

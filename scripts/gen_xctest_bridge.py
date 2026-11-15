#!/usr/bin/env python3
"""重新生成 Tests/IMECoreTests/XCTestBridge.swift（仅装 Command Line Tools、无 XCTest 时用 swift-testing 运行 XCTest 风格用例）。
用法：在项目根目录运行  python3 scripts/gen_xctest_bridge.py"""
import re, glob, os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Tests', 'IMECoreTests'))
out=['// FIX(CLT): 自动生成 —— 把每个 XCTestCase 测试方法注册为 swift-testing 的 @Test（每个用例新建实例，串行执行）。',
     '// 由 scripts/gen_xctest_bridge.py 生成；装了 Xcode（canImport(XCTest)）时不启用。','#if !canImport(XCTest)','import Testing','']
total=0
for f in sorted(glob.glob('*Tests.swift')):
    src=open(f).read()
    classes=[(m.start(), m.group(2), bool(m.group(1))) for m in re.finditer(r'(@MainActor\s*\n)?final class (\w+): XCTestCase', src)]
    for i,(pos,name,main) in enumerate(classes):
        end=classes[i+1][0] if i+1<len(classes) else len(src)
        tests=re.findall(r'\n\s*func (test\w*)\(\)\s*(async)?\s*(throws)?', src[pos:end])
        if not tests: continue
        out.append(f'@Suite("{name}", .serialized) struct {name}_Bridge {{')
        for t,a,th in tests:
            total+=1
            iso='@MainActor ' if main else ''
            call=('try ' if th else '')+('await ' if a else '')+f'{name}().{t}()'
            out.append(f'    @Test {iso}func {t}() async throws {{ {call} }}')
        out.append('}\n')
out.append('#endif')
open('XCTestBridge.swift','w').write('\n'.join(out)+'\n')
print(f'{total} tests bridged')

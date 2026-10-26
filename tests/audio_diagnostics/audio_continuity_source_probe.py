"""Compile current production render code in a small deterministic harness.
Only unused AutoEQ/loudness integrations are stand-ins; gain, EQ, queues, channel
mapping, format checks, fades, and routing predicates are actual production code.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[2]
def member(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
controller = (root/'Anchor/Audio/PerApp/Engine/ProcessTapController.swift').read_text()
context = (root/'Anchor/Audio/PerApp/Engine/TapRenderContext.swift').read_text().replace('import AnchorUtilities\n', '')
make = member(context, '    static func make(')
context = context.replace(make, '')
state = member((root/'Anchor/Audio/PerAppAudioManager.swift').read_text(), 'struct PerAppAudioState:').replace(', Defaults.Serializable', '')
stubs = '''
class AutoEQProcessor { var isEnabled: Bool { false }; func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {} }
class LoudnessCompensator: AutoEQProcessor {}
class LoudnessEqualizer { var isEnabled: Bool { false }; func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {} }
'''
Path(sys.argv[1]).write_text(context+'\n'+state+'\n'+stubs+'\nenum ProductionProbe {\n'+member(controller, 'nonisolated static func processMappedBuffers(')+'\n}\n'+(root/'tests/audio_diagnostics/AudioContinuityTests.swift').read_text())

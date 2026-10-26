"""Source/tooling checks only; these do not establish in-game API behavior."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import check_all
import sync_dev
import summarize_log
spec = importlib.util.spec_from_file_location("wbl_package", ROOT / "tools" / "package.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def make_mod(root: Path, file: str = "UI/Panel.xml") -> Path:
    mod = root / "Example"
    (mod / "UI").mkdir(parents=True)
    (mod / "UI" / "Panel.xml").write_text('<Context Name="Panel"/>')
    (mod / "UI" / "Panel.lua").write_text("return true")
    (mod / "Example.modinfo").write_text(f'''<Mod id="example"><Dependencies><Mod id="{check_all.GS_ID}"/></Dependencies>
    <ActionCriteria><Criteria id="XP2"><GameCoreInUse>Expansion2</GameCoreInUse></Criteria></ActionCriteria>
    <InGameActions><AddUserInterfaces><File>{file}</File></AddUserInterfaces></InGameActions>
    <Files><File>{file}</File><File>UI/Panel.lua</File></Files></Mod>''')
    return mod


class ManifestTests(unittest.TestCase):
    def test_manifest_rejects_escape_and_windows_paths(self):
        for path in ("../secret", "/secret", "C:/secret", "UI\\file", "UI/../file", "UI/file. ", "UI//file"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                check_all.safe_relative(path)

    def test_manifest_requires_files_and_ui_sibling(self):
        with tempfile.TemporaryDirectory() as temp:
            mod = make_mod(Path(temp))
            self.assertEqual(len(check_all.manifest_files(mod)), 3)
            (mod / "UI" / "Panel.lua").unlink()
            with self.assertRaises(ValueError):
                check_all.manifest_files(mod)

    def test_rejects_unlisted_files_and_missing_localization(self):
        with tempfile.TemporaryDirectory() as temp:
            mod = make_mod(Path(temp))
            (mod / "extra.txt").write_text("internal")
            (mod / "UI" / "Panel.xml").write_text('<Context><Label String="LOC_WBL_MISSING"/></Context>')
            errors = check_all.check_manifest(mod)
            self.assertTrue(any("unlisted" in error for error in errors))
            self.assertTrue(any("LOC_WBL_MISSING" in error for error in errors))

    def test_archive_contains_manifest_only_and_same_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            mod = make_mod(base)
            (mod / "secret.md").write_text("not a package member")
            output = packager.package(mod, base / "release.zip")
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()), {"Example/Example.modinfo", "Example/UI/Panel.xml", "Example/UI/Panel.lua"})
                for name in archive.namelist():
                    self.assertEqual(archive.read(name), (base / name).read_bytes())


class PolicyTests(unittest.TestCase):
    def test_unknown_engine_call_and_tunable_fail(self):
        errors = check_all.audit_lua("UI/Test.lua", "UI.InventedAPI(125)", {"apis": {}, "numbers": {}})
        self.assertTrue(any("InventedAPI" in error for error in errors))
        self.assertTrue(any("125" in error for error in errors))

    def test_comments_and_strings_do_not_look_like_engine_calls(self):
        source = '-- UI.Fake(99)\nlocal text="UI.Fake(99)"\n--[[ Game:SetProperty(4) ]]\nreturn true'
        self.assertEqual(check_all.engine_calls(source), set())
        self.assertEqual(check_all.audit_lua("Test.lua", source, {}), [])

    def test_nested_engine_calls_are_audited(self):
        calls = check_all.engine_calls("city:GetGrowth():GetAmenities(); PlayerConfigurations[player:GetID()]:GetHandicapTypeID()")
        self.assertEqual(calls, {"city:GetGrowth", "city:GetGrowth():GetAmenities", "player:GetID", "PlayerConfigurations[]:GetHandicapTypeID"})
        self.assertEqual(check_all.engine_calls('local text="x" .. player:GetID()'), {"player:GetID"})

    def test_gameplay_rules_apply_to_dev_entrypoints(self):
        for source in ("Game.GetLocalPlayer()", "math.random()", "for k,v in pairs(state) do end", "Events.TurnBegin.Add(Mutate)"):
            with self.subTest(source=source):
                self.assertTrue(check_all.audit_gameplay("WBL_Dev/Scripts/WBL_Spikes.lua", source))
        self.assertFalse(check_all.audit_gameplay("WBL_Dev/Scripts/WBL_Spikes.lua", "GameEvents.OnGameTurnStarted.Add(OnTurn)\nfor _,v in ipairs(state) do end"))

    def test_generated_copy_drift_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "WBL" / "Scripts"
            source.mkdir(parents=True)
            for name in sync_dev.IMPORTS:
                (source / name).write_bytes(b"authoritative\r\n")
            self.assertFalse(sync_dev.sync(root))
            self.assertFalse(sync_dev.sync(root, check=True))
            (root / "WBL_Dev" / "Scripts" / "WBL_Config.lua").write_bytes(b"drift")
            self.assertTrue(sync_dev.sync(root, check=True))


class LogTests(unittest.TestCase):
    def test_unknown_pending_and_summary_are_not_passes(self):
        report = summarize_log.summarize('[SPIKE S1] actual=1 PASS\n[SPIKE S2] PENDING engine\n[SPIKE S3] UNVERIFIED rate\n[SPIKE S4] raw=17\n[SUMMARY] 1 PASS, 0 FAIL')
        self.assertEqual(report.counts["PASS"], 1)
        self.assertEqual(report.counts["FAIL"], 0)
        self.assertEqual(report.counts["PENDING"], 1)
        self.assertEqual(report.counts["UNVERIFIED"], 1)
        self.assertEqual(report.counts["UNKNOWN"], 1)
        self.assertEqual(report.exit_code, 2)

    def test_latest_run_and_errors(self):
        report = summarize_log.summarize('[WBL RUN] BEGIN\n[SPIKE S1] FAIL\n[WBL RUN] BEGIN\n[SPIKE S1] PASS\nRuntime Error: broken')
        self.assertEqual(report.counts["FAIL"], 0)
        self.assertEqual(report.counts["PASS"], 1)
        self.assertEqual(report.exit_code, 1)

    def test_harness_failure_is_fatal(self):
        report = summarize_log.summarize("[WBL RUN] BEGIN\n[SPIKE HARNESS] FAIL request callback broken")
        self.assertEqual(report.exit_code, 1)
        self.assertEqual(len(report.errors), 1)

    def test_all_expected_observations_required(self):
        report = summarize_log.summarize("\n".join(f"[SPIKE S{i}] PASS" for i in range(1, 13)))
        self.assertEqual(report.exit_code, 0)
        self.assertEqual(summarize_log.summarize("").exit_code, 2)


class UITests(unittest.TestCase):
    def runtime(self, multiplayer=False, hotseat=False, stack=True):
        from lupa.lua51 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
          print=function() end
          requests = {}; selected = {}; currentID = 0; status = nil
          function Control()
            local control = {callbacks={}}
            function control:SetHide(v) self.hidden=v end
            function control:SetDisabled(v) self.disabled=v end
            function control:SetText(v) self.text=v end
            function control:SetToolTipString(v) self.tooltip=v end
            function control:RegisterCallback(k,v) self.callbacks[k]=v end
            function control:CalculateSize() end
            function control:GetSizeX() return 600 end
            function control:SetSizeX(v) self.width=v end
            return control
          end
          Controls = setmetatable({}, {__index=function(t,k) local v=Control(); rawset(t,k,v); return v end})
          function Event()
            local event={handlers={}}
            event.Add=function(f) event.handlers[f]=true end
            event.Remove=function(f) event.handlers[f]=nil end
            event.Fire=function() for f in pairs(event.handlers) do f() end end
            return event
          end
          Events={LoadGameViewStateDone=Event(), GameCoreEventPublishComplete=Event(), PlayerTurnActivated=Event()}
          LuaEvents={LaunchBar_Resize=function(w) launchWidth=w end}
          Mouse={eLClick=1}; Keys={D=68,VK_ESCAPE=27}; KeyEvents={KeyUp=1}
          Game={GetLocalPlayer=function() return currentID end, GetProperty=function(_,key) assert(key=='WBL_SPIKE_STATUS'); return status end}
          GameConfiguration={IsAnyMultiplayer=function() return multiplayer end, IsHotseat=function() return hotseat end}
          PlayerOperations={EXECUTE_SCRIPT=99}
          UI={RequestPlayerOperation=function(p,op,args) requests[#requests+1]={player=p,op=op,args=args} end,
              SelectCity=function(city) selected[#selected+1]=city end}
          local city={id=5}; local cities={FindID=function(_,id) if id==5 then return city end end}
          Players={[0]={GetCities=function() return cities end}}
          local target=Control()
          ContextPtr={SetHide=function(self,v) self.hidden=v end,
            SetInputHandler=function(self,f) self.input=f end, SetShutdown=function(self,f) self.shutdown=f end,
            LookUpControl=function(_,path) if haveStack then return target end end,
            BuildInstanceForControl=function(_,name,instance,stack) builds=(builds or 0)+1; instance.LaunchItemButton=Control(); instance.Pin=Control() end}
        ''')
        lua.globals().multiplayer = multiplayer
        lua.globals().hotseat = hotseat
        lua.globals().haveStack = stack
        lua.execute((ROOT / "WBL_Dev" / "UI" / "WBL_Dev_Panel.lua").read_text())
        return lua

    def test_clicks_route_flat_synced_requests(self):
        lua = self.runtime()
        lua.execute("Controls.RunButton.callbacks[1](); Controls.ReloadButton.callbacks[1]()")
        self.assertEqual(lua.eval("#requests"), 2)
        self.assertEqual(lua.eval("requests[1].args.OnStart"), "WBL_RunAllSpikes")
        self.assertEqual(lua.eval("requests[2].args.OnStart"), "WBL_ReloadConfig")
        self.assertFalse(lua.eval("ContextPtr.hidden"))

    def test_multiplayer_and_hotseat_block_both_requests(self):
        for multiplayer, hotseat in ((True, False), (False, True)):
            with self.subTest(multiplayer=multiplayer, hotseat=hotseat):
                lua = self.runtime(multiplayer, hotseat)
                lua.execute("Controls.RunButton.callbacks[1](); Controls.ReloadButton.callbacks[1]()")
                self.assertTrue(lua.eval("Controls.ReloadButton.disabled"))
                self.assertTrue(lua.eval("Controls.RunButton.disabled"))
                self.assertEqual(lua.eval("#requests"), 0)

    def test_no_local_player_cannot_send(self):
        lua = self.runtime()
        lua.execute("currentID=-1; Controls.RunButton.callbacks[1]()")
        self.assertEqual(lua.eval("#requests"), 0)

    def test_missing_launchbar_keeps_visible_fallback(self):
        lua = self.runtime(stack=False)
        lua.execute("Events.LoadGameViewStateDone.Fire(); Controls.FallbackButton.callbacks[1]()")
        self.assertFalse(lua.eval("Controls.FallbackButton.hidden"))
        self.assertFalse(lua.eval("Controls.Main.hidden"))

    def test_launchbar_attaches_once_and_keeps_visual_pending(self):
        lua = self.runtime()
        lua.execute("Events.LoadGameViewStateDone.Fire(); Events.LoadGameViewStateDone.Fire()")
        self.assertEqual(lua.eval("builds"), 2)
        self.assertTrue(lua.eval("Controls.FallbackButton.hidden"))
        self.assertIn("PENDING", lua.eval("Controls.EntryLabel.text"))

    def test_hotkey_and_city_selection_display_only(self):
        lua = self.runtime()
        lua.execute('''input={GetMessageType=function() return 1 end, GetKey=function() return 68 end,
          IsControlDown=function() return true end, IsShiftDown=function() return true end}
          assert(ContextPtr.input(input)); assert(Controls.Main.hidden==false)
          status={phase='S4_APPLIED',text='Probe active',playerID=0,cityID=5,runID=1,turn=2,pass=1,fail=0,pending=10}
          Events.GameCoreEventPublishComplete.Fire(); Events.GameCoreEventPublishComplete.Fire()
        ''')
        self.assertEqual(lua.eval("#selected"), 1)
        self.assertTrue(lua.eval("Controls.Main.hidden"))
        self.assertIn("S4_APPLIED", lua.eval("Controls.StatusLabel.text"))
        self.assertEqual(lua.eval("#requests"), 0)


class InstallerTests(unittest.TestCase):
    def powershell(self):
        return shutil.which("pwsh") or shutil.which("powershell")

    def test_running_game_refused_before_checks(self):
        shell = self.powershell()
        if not shell:
            self.skipTest("PowerShell unavailable")
        script = f"function Get-Process {{ param($Name,$ErrorAction) [pscustomobject]@{{ProcessName='CivilizationVI'}} }}; & '{ROOT / 'tools' / 'install.ps1'}' -ModsPath '{ROOT}' -DevOnly -DryRun"
        result = subprocess.run([shell, "-NoProfile", "-Command", script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Civilization VI is running", result.stdout + result.stderr)

    def test_dry_run_does_not_create_destination(self):
        shell = self.powershell()
        if not shell:
            self.skipTest("PowerShell unavailable")
        # Source checker runs for real; this test must fail if repository checks fail.
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run([shell, "-NoProfile", "-File", str(ROOT / "tools" / "install.ps1"), "-ModsPath", temp, "-DevOnly", "-DryRun", "-Python", sys.executable], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(list(Path(temp).iterdir()), [])
            self.assertIn("DRY RUN", result.stdout)


if __name__ == "__main__":
    unittest.main()

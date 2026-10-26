"""Runs real S3 UI helper against a fake engine, never a live diplomacy test."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]


class DealProbeTests(unittest.TestCase):
    def runtime(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
          logs={}; print=function(line) logs[#logs+1]=line end
          currentTurn=1; localID=0; multiplayer=false; hotseat=false; human=true
          sessions={}; sessionInfo={}; drafts={}; pending={}; requests={}; sent={}; closed={}
          nextSession=0; nextItem=0; cash={[0]=5000,[1]=5000}; itemMaximum=10000
          DealDirection={OUTGOING=1,INCOMING=2}; DealItemTypes={GOLD=1}
          DealProposalAction={INSPECT=1,ACCEPTED=2,REJECTED=3,PROPOSED=4}
          DealValidationResult={VALID=0}
          function NewItem(from,kind,amount,duration)
            nextItem=nextItem+1
            local item={id=nextItem,from=from,kind=kind,amount=amount or 0,duration=duration or 0}
            function item:GetID() return self.id end
            function item:GetType() return self.kind end
            function item:GetFromPlayerID() return self.from end
            function item:GetAmount() return self.amount end
            function item:GetDuration() return self.duration end
            function item:GetMaxAmount() return itemMaximum end
            function item:SetDuration(v) self.duration=v end
            function item:SetAmount(v) if failSetter then error('setter_failure') end; self.amount=v end
            return item
          end
          function NewDeal()
            local deal={items={}}
            function deal:Items()
              local index=0
              return function() index=index+1; return self.items[index] end
            end
            function deal:GetItemCount() return #self.items end
            function deal:AddItemOfType(kind,from)
              local item=NewItem(from,kind); self.items[#self.items+1]=item; return item
            end
            function deal:RemoveItemByID(id)
              if failCleanup then error('remove_failure') end
              for index,item in ipairs(self.items) do
                if item.id==id then table.remove(self.items,index); return end
              end
            end
            function deal:Validate() return invalidDeal and 1 or 0 end
            return deal
          end
          drafts[1]={[1]=NewDeal(),[2]=NewDeal()}
          local player={}
          function player:GetID() return 0 end
          function player:IsHuman() return human end
          function player:GetDiplomacy()
            return {HasMet=function() return not unmet end,IsAtWarWith=function() return false end}
          end
          function player:GetTreasury() return {GetGoldBalance=function() return cash[0] end} end
          local ai={}
          function ai:GetID() return 1 end
          function ai:IsHuman() return false end
          function ai:GetDiplomaticAI() return {GetDiplomaticStateIndex=function() return 7 end} end
          function ai:GetTreasury() return {GetGoldBalance=function() return cash[1] end} end
          Players={[0]=player,[1]=ai}
          PlayerManager={GetAliveMajors=function() return {ai,player} end}
          Game={GetLocalPlayer=function() return localID end,GetCurrentGameTurn=function() return currentTurn end}
          GameConfiguration={IsAnyMultiplayer=function() return multiplayer end,IsHotseat=function() return hotseat end}
          GameInfo={DiplomaticStates={[7]={Name='FRIENDLY'}}}
          DealManager={
            GetWorkingDeal=function(direction,from,other) return drafts[other] and drafts[other][direction] end,
            HasPendingDeal=function(from,other) return pending[other]==true end,
            SendWorkingDeal=function(action,from,other)
              assert(action==DealProposalAction.INSPECT,'binding_operation_forbidden')
              local d=drafts[other][1]
              sent[#sent+1]={action=action,from=from,other=other,session=sessions[other],
                principal=d.items[1].amount,gpt=d.items[2].amount,duration=d.items[2].duration}
            end}
          DiplomacyManager={
            FindOpenSessionID=function(from,other) return sessions[other] end,
            GetSessionInfo=function(id) return sessionInfo[id] end,
            GetKeyName=function(key) return key end,
            RequestSession=function(from,other,kind)
              assert(kind=='MAKE_DEAL'); assert(sessions[other]==nil)
              nextSession=nextSession+1; sessions[other]=nextSession
              sessionInfo[nextSession]={FromPlayer=from}
              requests[#requests+1]={from=from,other=other,session=nextSession}
            end,
            CloseSession=function(id)
              closed[#closed+1]=id
              for other,value in pairs(sessions) do if value==id then sessions[other]=nil end end
            end}
          config={spikes={comparisonGold={100},dealGPTMin=1,dealGPTMax=8,dealTurns=30,
            minAttitudeSamples=3,dealQueryTimeoutSeconds=8,dealRunTimeoutSeconds=120}}
          status={runID=1,playerID=0,phase='OBSERVING'}
        ''')
        lua.execute((ROOT / "WBL_Dev/UI/WBL_Dev_Deals.lua").read_text())
        lua.execute('''
          function Begin() WBL_DEALS.Arm(nil); WBL_DEALS.Observe(status,config) end
          function Open()
            local r=requests[#requests]
            WBL_DEALS.OnStatement(r.other,r.from,{StatementType='MAKE_DEAL',RespondingToDealAction=0,
              DealAction=0,SessionID=r.session})
          end
          function Respond(accepted,copyIncoming)
            local r=sent[#sent]
            if copyIncoming then
              drafts[r.other][2].items={}
              for _,item in ipairs(drafts[r.other][1].items) do
                local copy=NewItem(item.from,item.kind,item.amount,item.duration)
                table.insert(drafts[r.other][2].items,copy)
              end
            end
            WBL_DEALS.OnStatement(r.other,r.from,{StatementType='MAKE_DEAL',
              RespondingToDealAction=DealProposalAction.INSPECT,
              DealAction=accepted and DealProposalAction.ACCEPTED or DealProposalAction.REJECTED,SessionID=r.session})
          end
        ''')
        return lua

    def test_requires_new_armed_synced_run(self):
        lua = self.runtime()
        lua.execute("WBL_DEALS.Observe(status,config)")
        self.assertEqual(lua.eval("#requests"), 0)
        lua.execute("WBL_DEALS.Arm(1); WBL_DEALS.Observe(status,config)")
        self.assertEqual(lua.eval("#requests"), 0)
        lua.execute("status.runID=2; WBL_DEALS.Observe(status,config); WBL_DEALS.Observe(status,config)")
        self.assertEqual(lua.eval("#requests"), 1)

    def test_multiplayer_hotseat_and_nonhuman_refuse(self):
        for flag in ("multiplayer", "hotseat", "human"):
            with self.subTest(flag=flag):
                lua = self.runtime()
                lua.execute(f"{flag}={'false' if flag == 'human' else 'true'}; Begin()")
                self.assertEqual(lua.eval("#requests"), 0)
                self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))

    def test_existing_session_and_pending_proposal_untouched(self):
        for setup in ("sessions[1]=77;sessionInfo[77]={FromPlayer=0}", "pending[1]=true"):
            lua = self.runtime()
            lua.execute(setup + "; Begin()")
            self.assertEqual(lua.eval("#requests"), 0)
            self.assertEqual(lua.eval("#closed"), 0)
            self.assertEqual(lua.eval("#sent"), 0)

    def test_existing_draft_identity_and_content_preserved(self):
        lua = self.runtime()
        lua.execute("existing=NewItem(0,99,45,17); drafts[1][1].items={existing}; Begin()")
        self.assertEqual(lua.eval("#requests"), 0)
        self.assertTrue(lua.eval("drafts[1][1].items[1]==existing"))
        self.assertEqual(lua.eval("existing.amount"), 45)

    def test_binary_candidate_logs_only_actual_responses_and_never_binds(self):
        lua = self.runtime()
        lua.execute('''Begin(); safety=0
          while WBL_DEALS.IsBusy() do
            safety=safety+1; assert(safety<20)
            Open(); local request=sent[#sent]; Respond(request.gpt<=3,true); WBL_DEALS.Update(0)
          end''')
        self.assertEqual(lua.eval("#sent"), 5)
        self.assertEqual(lua.eval("#closed"), 5)
        self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()+drafts[1][2]:GetItemCount()"), 0)
        self.assertEqual(lua.eval("cash[0]+cash[1]"), 10000)
        logs = lua.eval("table.concat(logs, string.char(10))")
        self.assertIn("greatest_observed_accepted_GPT=3", logs)
        self.assertIn("required_attitudes=3", logs)
        self.assertIn("inspectAccepted=true", logs)
        self.assertNotIn(" PASS", logs)

    def test_wrong_or_late_response_ignored(self):
        lua = self.runtime()
        lua.execute('''Begin(); Open(); oldSession=sent[1].session
          WBL_DEALS.OnStatement(1,0,{StatementType='MAKE_DEAL',RespondingToDealAction=1,DealAction=2,SessionID=999})
        ''')
        self.assertEqual(lua.eval("#closed"), 0)
        lua.execute("Respond(true,true); WBL_DEALS.Update(0); Open()")
        self.assertEqual(lua.eval("#sent"), 2)
        lua.execute("WBL_DEALS.OnStatement(1,0,{StatementType='MAKE_DEAL',RespondingToDealAction=1,DealAction=2,SessionID=oldSession})")
        self.assertEqual(lua.eval("#closed"), 1)

    def test_query_timeout_cleans_correlated_owned_session(self):
        lua = self.runtime()
        lua.execute("Begin(); Open(); WBL_DEALS.Update(8)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#closed"), 1)
        self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()"), 0)
        self.assertIn("queries timed out", lua.eval("WBL_DEALS.Status()"))

    def test_opening_timeout_preserves_uncorrelated_same_pair_session(self):
        lua = self.runtime()
        lua.execute("Begin(); sessions[1]=777;sessionInfo[777]={FromPlayer=0};WBL_DEALS.Update(8)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#closed"), 0)
        self.assertEqual(lua.eval("sessions[1]"), 777)
        self.assertIn("cleanup_ownership_unknown", lua.eval("table.concat(logs, string.char(10))"))

    def test_replacement_session_preserves_drafts_before_any_removal(self):
        lua = self.runtime()
        lua.execute("Begin();Open();sessions[1]=777;sessionInfo[777]={FromPlayer=0};WBL_DEALS.Update(8)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#closed"), 0)
        self.assertEqual(lua.eval("sessions[1]"), 777)
        self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()"), 2)

    def test_legal_GPT_ceiling_still_finds_observed_candidate(self):
        lua = self.runtime()
        lua.execute('''
          originalNewItem=NewItem
          NewItem=function(from,kind,amount,duration)
            local item=originalNewItem(from,kind,amount,duration)
            function item:GetMaxAmount() return self.from==1 and 5 or 5000 end
            return item
          end
          Begin(); safety=0
          while WBL_DEALS.IsBusy() do
            safety=safety+1; assert(safety<20)
            Open(); local request=sent[#sent]; Respond(request.gpt<=3,true); WBL_DEALS.Update(0)
          end
        ''')
        log = lua.eval("table.concat(logs,string.char(10))")
        self.assertIn("legalGPTCeiling=5", log)
        self.assertIn("greatest_observed_accepted_GPT=3", log)

    def test_NaN_delta_cannot_disable_timeout(self):
        lua = self.runtime()
        lua.execute("Begin(); Open(); WBL_DEALS.Update(0/0); WBL_DEALS.Update(8)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))

    def test_missing_synced_run_has_bounded_wait(self):
        lua = self.runtime()
        lua.execute("WBL_DEALS.Arm(1,config);WBL_DEALS.Update(8)")
        self.assertIn("queries stopped", lua.eval("WBL_DEALS.Status()"))

    def test_global_timeout_is_separate(self):
        lua = self.runtime()
        lua.execute("config.spikes.dealRunTimeoutSeconds=2; Begin(); WBL_DEALS.Update(2)")
        self.assertIn("whole_run_timeout", lua.eval("WBL_DEALS.Status()"))

    def test_setter_failure_removes_only_owned_items(self):
        lua = self.runtime()
        lua.execute("Begin(); failSetter=true; Open()")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()"), 0)
        self.assertEqual(lua.eval("#sent"), 0)
        self.assertEqual(lua.eval("#closed"), 1)

    def test_foreign_incoming_preserves_all_drafts_and_session(self):
        lua = self.runtime()
        lua.execute("Begin(); Open(); foreign=NewItem(1,99,70,9);drafts[1][2].items={foreign};Respond(true,false)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#closed"), 0)
        self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()"), 2)
        self.assertTrue(lua.eval("drafts[1][2].items[1]==foreign"))

    def test_changed_owned_id_is_preserved_after_inspection(self):
        lua = self.runtime()
        lua.execute("Begin();Open();drafts[1][1].items[1].amount=444;Respond(true,false)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("drafts[1][1].items[1].amount"), 444)
        self.assertEqual(lua.eval("#closed"), 0)

    def test_cash_change_is_failure_and_aborts(self):
        lua = self.runtime()
        lua.execute("Begin();Open();cash[0]=cash[0]-100;Respond(true,true)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertIn("cash_changed_during_inspection", lua.eval("WBL_DEALS.Status()"))
        self.assertIn("FAIL", lua.eval("table.concat(logs, string.char(10))"))

    def test_unreadable_cash_never_claims_unchanged_or_sends(self):
        lua = self.runtime()
        lua.execute("Begin(); cash[0]=nil; Open()")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#sent"), 0)
        self.assertEqual(lua.eval("#closed"), 1)
        self.assertNotIn("cashUnchanged=true", lua.eval("table.concat(logs,string.char(10))"))

    def test_turn_change_and_shutdown_abort_with_cleanup(self):
        for action in ("currentTurn=2;WBL_DEALS.Update(0)", "WBL_DEALS.Shutdown()"):
            lua = self.runtime()
            lua.execute("Begin();Open();" + action)
            self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
            self.assertEqual(lua.eval("drafts[1][1]:GetItemCount()"), 0)
            self.assertEqual(lua.eval("#closed"), 1)

    def test_infeasible_legality_is_not_rejection(self):
        lua = self.runtime()
        lua.execute("itemMaximum=50;Begin();Open();WBL_DEALS.Update(0)")
        self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
        self.assertEqual(lua.eval("#sent"), 0)
        self.assertIn("sample_infeasible_not_rejected", lua.eval("table.concat(logs, string.char(10))"))

    def test_invalid_config_and_unmet_AI_remain_pending(self):
        for setup in ("config.spikes.dealGPTMin=0", "unmet=true"):
            lua = self.runtime()
            lua.execute(setup + ";Begin()")
            self.assertFalse(lua.eval("WBL_DEALS.IsBusy()"))
            self.assertEqual(lua.eval("#requests"), 0)


if __name__ == "__main__":
    unittest.main()

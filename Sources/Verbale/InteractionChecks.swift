import Foundation
import VerbaleCore

extension AppModel {
    /// Isolated Preview only: exercise the real draft/save/export path on synthetic documents.
    func checkResponsiveEdits(root:URL,checks:inout [String:Bool]) async throws {
        let destination=root.appendingPathComponent("InteractionChecks")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        var a=Meeting(title:"Note A",sources:[.system],destination:destination,keepAudio:false)
        a.state = .complete;a.notes="Prima";a.report="Report precedente"
        a.segments=[Segment(source:.system,start:0,end:3,text:"Test sintetico",speakerID:"1")]
        var b=Meeting(title:"Note B",sources:[.system],destination:destination,keepAudio:false);b.state = .complete;b.notes="Altra riunione"
        try store.save(a);a=try store.export(a);try store.save(b);b=try store.export(b)
        meetings += [a,b];current=a;busy=false;working=false;isRecording=false;reportBusy=false
        let path=store.workspace(a.id).appendingPathComponent("meeting.json"),before=try Data(contentsOf:path)
        var notifications=0
        let observer=objectWillChange.sink {notifications += 1}
        let start=ProcessInfo.processInfo.systemUptime
        for i in 0..<1000 {noteDrafts.edit("Bozza \(i)",id:a.id)}
        let typing=ProcessInfo.processInfo.systemUptime-start
        observer.cancel()
        checks["notes typing does not invalidate the global app model"] = notifications==0
        checks["notes typing does not persist per keystroke"] = try Data(contentsOf:path)==before && current?.notes=="Prima"
        checks["thousand note edits fit within interactive budget"] = typing<0.2
        open(b)
        await flushVoiceSaves()
        let saved=try store.read(a.id)
        checks["notes flush persists latest draft after navigation"] = saved.notes=="Bozza 999" && current?.id==b.id && current?.notes=="Altra riunione"
        checks["notes invalidate prior report and preserve transcript"] = saved.reportNeedsUpdate && saved.segments.first?.id==a.segments.first?.id
        checks["notes flush updates output"] = try String(contentsOf:destination.appendingPathComponent(a.folderName).appendingPathComponent("notes.md"),encoding:.utf8)=="Bozza 999"
        checks["notes successful persistence clears draft"] = !noteDrafts.contains(a.id)
        let stable=try Data(contentsOf:path)
        try FileManager.default.removeItem(at:path)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
        noteDrafts.edit("Da recuperare",id:a.id)
        await flushVoiceSaves()
        checks["notes failed private save retains editable draft"] = noteDrafts.failures.contains(a.id) && noteDrafts.text(for:a.id,fallback:"")=="Da recuperare" && hasUnsavedEdits
        try FileManager.default.removeItem(at:path);try stable.write(to:path,options:.atomic)
        noteDrafts.commit(a.id);await flushVoiceSaves()
        checks["notes retry recovers failed draft"] = try store.read(a.id).notes=="Da recuperare" && !noteDrafts.contains(a.id)
        open(a)
        noteDrafts.edit("Salvataggio prima del report",id:a.id)
        await flushVoiceSaves()
        checks["report flush sees latest notes in durable source"] = try store.read(a.id).notes=="Salvataggio prima del report" && !savingVoiceMeetings.contains(a.id)
        // A live recording keeps checkpoint ownership on the capture path.
        // A retry must write even if the optimistic text already matches.
        open(a);isRecording=true
        let activeStable=try Data(contentsOf:path)
        try FileManager.default.removeItem(at:path);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
        noteDrafts.edit("Bozza attiva da recuperare",id:a.id);await flushVoiceSaves()
        checks["notes active checkpoint failure retains draft"] = noteDrafts.failures.contains(a.id)
        try FileManager.default.removeItem(at:path);try activeStable.write(to:path,options:.atomic)
        noteDrafts.commit(a.id);await flushVoiceSaves()
        checks["notes active checkpoint retry writes matching optimistic text"] = try store.read(a.id).notes=="Bozza attiva da recuperare" && !noteDrafts.contains(a.id)
        isRecording=false;error=nil
        let result:[String:Any] = ["typing1000Milliseconds":typing*1000,"checks":checks.filter{$0.key.hasPrefix("notes ") || $0.key.hasPrefix("report flush") || $0.key.hasPrefix("thousand note")}]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("interaction-verification.json"))
    }
}

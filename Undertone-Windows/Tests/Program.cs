using System;
using Undertone;
static void Check(bool condition) { if (!condition) throw new Exception("Timer regression"); }
var start = DateTimeOffset.UnixEpoch;
var timer = new Countdown();timer.Start(TimeSpan.FromSeconds(60),start);
timer.Toggle(start.AddSeconds(12.5));Check(timer.Paused);Check(timer.Remaining(start.AddDays(1)).TotalSeconds==47.5);
timer.Toggle(start.AddDays(1));Check(!timer.Tick(start.AddDays(1).AddSeconds(47)));Check(timer.Tick(start.AddDays(1).AddSeconds(48)));Check(!timer.Tick(start.AddDays(2)));Check(timer.Finished);
timer.Cancel();Check(!timer.Active);Check(Countdown.Format(TimeSpan.FromSeconds(3601))=="1:00:01");
Console.WriteLine("PASS: Windows timer pause/resume, elapsed-time catch-up, completion and cancellation");

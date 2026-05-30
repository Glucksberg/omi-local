import argparse
import os
import re
import socket
import subprocess
import time
from dataclasses import dataclass

import psutil
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import Horizontal
from textual.widgets import DataTable, Footer, Header, Static

WATCH_PATTERNS = (
    'parakeet-server',
    'parakeet_local_listen_server.py',
    'run_parakeet_stream_server.sh',
    'run_parakeet_local_proxy.sh',
    '/Applications/Omi Local.app/Contents/MacOS/Omi Computer',
)


@dataclass
class BatterySnapshot:
    source: str = 'unknown'
    percent: str = '-'
    state: str = '-'
    remaining: str = '-'


@dataclass
class ThermalSnapshot:
    thermal: str = 'unknown'
    performance: str = 'unknown'
    cpu_power: str = 'unknown'


@dataclass
class Alert:
    level: str
    message: str


def _run(command: list[str], timeout: float = 2.0) -> str:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=timeout)
    except Exception as exc:
        return str(exc)


def battery_snapshot() -> BatterySnapshot:
    output = _run(['pmset', '-g', 'batt'])
    source_match = re.search(r"Now drawing from '([^']+)'", output)
    battery_match = re.search(r'\s(\d+%);\s*([^;]+);\s*([^\n]+)', output)
    remaining = '-'
    if battery_match:
        remaining = battery_match.group(3).replace(' present: true', '').replace(' present: false', '').strip()
    return BatterySnapshot(
        source=source_match.group(1) if source_match else 'unknown',
        percent=battery_match.group(1) if battery_match else '-',
        state=battery_match.group(2).strip() if battery_match else '-',
        remaining=remaining,
    )


def thermal_snapshot() -> ThermalSnapshot:
    output = _run(['pmset', '-g', 'therm'])
    thermal = 'ok'
    performance = 'ok'
    cpu_power = 'ok'
    if 'No thermal warning level has been recorded' not in output:
        thermal = 'warning'
    if 'No performance warning level has been recorded' not in output:
        performance = 'warning'
    if 'No CPU power status has been recorded' not in output:
        cpu_power = 'limited'
    return ThermalSnapshot(thermal=thermal, performance=performance, cpu_power=cpu_power)


def launchd_state(label: str) -> str:
    output = _run(['launchctl', 'print', f'gui/{os.getuid()}/{label}'], timeout=1.0)
    state = re.search(r'state = (\w+)', output)
    pid = re.search(r'pid = (\d+)', output)
    if state:
        return f'{state.group(1)}' + (f' pid {pid.group(1)}' if pid else '')
    return 'not loaded'


def port_state(port: int) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.2)
        return 'listening' if sock.connect_ex(('127.0.0.1', port)) == 0 else 'closed'


def watched_processes() -> list[psutil.Process]:
    matches: list[psutil.Process] = []
    for proc in psutil.process_iter(['pid', 'ppid', 'name', 'cmdline', 'cpu_percent', 'memory_info', 'create_time']):
        try:
            cmd = ' '.join(proc.info.get('cmdline') or [])
            if any(pattern in cmd for pattern in WATCH_PATTERNS):
                matches.append(proc)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return sorted(matches, key=lambda p: p.info['pid'])


def format_bytes(value: int) -> str:
    units = ('B', 'KB', 'MB', 'GB')
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f'{amount:.1f} {unit}' if unit != 'B' else f'{int(amount)} B'
        amount /= 1024
    return f'{amount:.1f} GB'


def elapsed_since(timestamp: float) -> str:
    seconds = max(0, int(time.time() - timestamp))
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f'{hours}h{minutes:02d}m'
    return f'{minutes}m{secs:02d}s'


def parse_percent(value: str) -> int | None:
    match = re.search(r'(\d+)', value)
    return int(match.group(1)) if match else None


def parse_remaining_minutes(value: str) -> int | None:
    match = re.search(r'(\d+):(\d+)', value)
    if not match:
        return None
    return int(match.group(1)) * 60 + int(match.group(2))


def severity_for_percent(value: float, warning: float, danger: float) -> str:
    if value >= danger:
        return 'danger'
    if value >= warning:
        return 'warning'
    return 'ok'


def severity_style(level: str) -> str:
    return {
        'danger': 'bold white on red',
        'warning': 'bold black on yellow',
        'ok': 'bold green',
        'info': 'cyan',
    }.get(level, 'white')


def badge(label: str, level: str) -> Text:
    return Text(f' {label} ', style=severity_style(level))


def value_text(value: str, level: str) -> Text:
    return Text(value, style=severity_style(level))


class OmiParakeetMonitor(App):
    CSS = """
    Screen {
        layout: vertical;
        background: #101218;
    }

    #summary {
        height: 10;
        padding: 1 2;
        border: tall $primary;
        background: #151923;
    }

    #summary.ok {
        border: tall #3fb950;
    }

    #summary.warning {
        border: tall #d29922;
    }

    #summary.danger {
        border: tall #f85149;
    }

    #alerts {
        height: 7;
        padding: 1 2;
        border: tall #30363d;
        background: #0d1117;
    }

    #alerts.ok {
        border: tall #3fb950;
    }

    #alerts.warning {
        border: tall #d29922;
    }

    #alerts.danger {
        border: tall #f85149;
    }

    #panes {
        height: 1fr;
    }

    DataTable {
        height: 1fr;
        border: tall #30363d;
        background: #0d1117;
    }

    #processes {
        width: 2fr;
    }

    #services {
        width: 1fr;
    }
    """

    BINDINGS = [('q', 'quit', 'Quit'), ('r', 'refresh', 'Refresh')]

    def __init__(self, interval: float):
        super().__init__()
        self.interval = interval
        self._last_total_cpu = 0.0
        self._last_total_rss = 0
        self._process_cpu_samples: dict[int, tuple[float, float]] = {}

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(id='summary')
        yield Static(id='alerts')
        with Horizontal(id='panes'):
            yield DataTable(id='processes')
            yield DataTable(id='services')
        yield Footer()

    def on_mount(self) -> None:
        self.title = 'Omi Local Parakeet Resource Monitor'
        process_table = self.query_one('#processes', DataTable)
        process_table.border_title = 'Watched processes'
        process_table.zebra_stripes = True
        process_table.add_columns('Risk', 'PID', 'CPU %', 'RAM', 'Uptime', 'Command')
        service_table = self.query_one('#services', DataTable)
        service_table.border_title = 'Services'
        service_table.zebra_stripes = True
        service_table.add_columns('Item', 'Value')
        self.set_interval(self.interval, self.refresh_metrics)
        self.refresh_metrics()

    def action_refresh(self) -> None:
        self.refresh_metrics()

    def process_cpu_percent(self, proc: psutil.Process, now: float) -> float:
        try:
            times = proc.cpu_times()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            return 0.0
        current = times.user + times.system
        previous = self._process_cpu_samples.get(proc.pid)
        self._process_cpu_samples[proc.pid] = (now, current)
        if not previous:
            return 0.0
        previous_time, previous_cpu = previous
        elapsed = max(0.001, now - previous_time)
        return max(0.0, (current - previous_cpu) / elapsed * 100.0)

    def refresh_metrics(self) -> None:
        battery = battery_snapshot()
        thermal = thermal_snapshot()
        vm = psutil.virtual_memory()
        cpu = psutil.cpu_percent(interval=None)
        processes = watched_processes()
        now = time.time()
        alerts: list[Alert] = []

        rows = []
        total_cpu = 0.0
        total_rss = 0
        for proc in processes:
            try:
                cmd = ' '.join(proc.info.get('cmdline') or [proc.info.get('name') or ''])
                rss = proc.info['memory_info'].rss
                proc_cpu = self.process_cpu_percent(proc, now)
                total_cpu += proc_cpu
                total_rss += rss
                risk = 'ok'
                if proc_cpu >= 150 or rss >= 2_500_000_000:
                    risk = 'danger'
                elif proc_cpu >= 60 or rss >= 1_500_000_000:
                    risk = 'warning'
                rows.append(
                    (
                        badge(risk.upper(), risk),
                        str(proc.info['pid']),
                        value_text(f'{proc_cpu:.1f}', severity_for_percent(proc_cpu, 60, 150)),
                        value_text(
                            format_bytes(rss),
                            'danger' if rss >= 2_500_000_000 else 'warning' if rss >= 1_500_000_000 else 'ok',
                        ),
                        elapsed_since(proc.info['create_time']),
                        cmd[:100],
                    )
                )
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        self._last_total_cpu = total_cpu
        self._last_total_rss = total_rss

        cpu_level = severity_for_percent(cpu, 70, 90)
        watched_cpu_level = severity_for_percent(total_cpu, 100, 250)
        system_ram_level = severity_for_percent(vm.percent, 80, 90)
        watched_ram_level = (
            'danger' if total_rss >= 4_000_000_000 else 'warning' if total_rss >= 2_000_000_000 else 'ok'
        )
        battery_level = 'ok'
        battery_percent = parse_percent(battery.percent)
        remaining_minutes = parse_remaining_minutes(battery.remaining)
        if battery.state == 'discharging':
            if (battery_percent is not None and battery_percent <= 15) or (
                remaining_minutes is not None and remaining_minutes <= 60
            ):
                battery_level = 'danger'
            elif (battery_percent is not None and battery_percent <= 30) or (
                remaining_minutes is not None and remaining_minutes <= 120
            ):
                battery_level = 'warning'
        thermal_level = 'danger' if thermal.thermal != 'ok' or thermal.performance != 'ok' else 'ok'
        cpu_power_level = 'warning' if thermal.cpu_power != 'ok' else 'ok'

        if cpu_level != 'ok':
            alerts.append(Alert(cpu_level, f'System CPU high: {cpu:.1f}%.'))
        if watched_cpu_level != 'ok':
            alerts.append(Alert(watched_cpu_level, f'Omi/Parakeet CPU high: {total_cpu:.1f}%.'))
        if system_ram_level != 'ok':
            alerts.append(Alert(system_ram_level, f'System RAM pressure high: {vm.percent:.1f}% used.'))
        if watched_ram_level != 'ok':
            alerts.append(Alert(watched_ram_level, f'Omi/Parakeet RAM high: {format_bytes(total_rss)}.'))
        if battery_level != 'ok':
            alerts.append(Alert(battery_level, f'Battery low: {battery.percent}, {battery.remaining}.'))
        if thermal_level != 'ok':
            alerts.append(Alert(thermal_level, 'macOS reports thermal or performance pressure.'))
        if cpu_power_level != 'ok':
            alerts.append(Alert(cpu_power_level, 'macOS reports CPU power limiting.'))

        parakeet_port = port_state(8765)
        proxy_port = port_state(8001)
        parakeet_launchd = launchd_state('com.omi.parakeet-stream')
        proxy_launchd = launchd_state('com.omi.parakeet-listen-proxy')
        if parakeet_port != 'listening':
            alerts.append(Alert('danger', 'Parakeet port 8765 is closed. STT local will not work.'))
        if proxy_port != 'listening':
            alerts.append(Alert('danger', 'Omi STT proxy port 8001 is closed. Omi cannot reach Parakeet.'))
        if not parakeet_launchd.startswith('running'):
            alerts.append(Alert('danger', f'Parakeet LaunchAgent is {parakeet_launchd}.'))
        if not proxy_launchd.startswith('running'):
            alerts.append(Alert('danger', f'Proxy LaunchAgent is {proxy_launchd}.'))

        overall = 'danger' if any(alert.level == 'danger' for alert in alerts) else 'warning' if alerts else 'ok'

        summary = Text()
        summary.append('Omi Local + Parakeet resource monitor\n', style='bold white')
        summary.append_text(badge(f'STATUS {overall.upper()}', overall))
        summary.append('  ')
        summary.append_text(badge(f'SYSTEM CPU {cpu:.1f}%', cpu_level))
        summary.append('  ')
        summary.append_text(badge(f'OMI/PARAKEET CPU {total_cpu:.1f}%', watched_cpu_level))
        summary.append('\n')
        summary.append_text(badge(f'OMI/PARAKEET RAM {format_bytes(total_rss)}', watched_ram_level))
        summary.append('  ')
        summary.append_text(badge(f'SYSTEM RAM {vm.percent:.1f}%', system_ram_level))
        summary.append('  ')
        summary.append_text(badge(f'BATTERY {battery.percent} {battery.remaining}', battery_level))
        summary.append('\n')
        summary.append_text(badge(f'THERMAL {thermal.thermal}', thermal_level))
        summary.append('  ')
        summary.append_text(badge(f'PERFORMANCE {thermal.performance}', thermal_level))
        summary.append('  ')
        summary.append_text(badge(f'CPU POWER {thermal.cpu_power}', cpu_power_level))
        summary.append(f'\nUpdated {time.strftime("%H:%M:%S")} every {self.interval:g}s')
        summary_widget = self.query_one('#summary', Static)
        summary_widget.set_class(overall == 'ok', 'ok')
        summary_widget.set_class(overall == 'warning', 'warning')
        summary_widget.set_class(overall == 'danger', 'danger')
        summary_widget.update(summary)

        alert_text = Text()
        if alerts:
            alert_text.append('Alerts\n', style='bold white')
            for alert in alerts[:5]:
                alert_text.append_text(badge(alert.level.upper(), alert.level))
                alert_text.append(f' {alert.message}\n', style=severity_style(alert.level))
            if any(alert.level == 'danger' for alert in alerts):
                alert_text.append(
                    'Action: stop ambient recording or unload Parakeet if the Mac gets hot.\n', style='bold red'
                )
            elif alerts:
                alert_text.append('Action: keep watching during PTT/ambient recording.\n', style='yellow')
        else:
            alert_text.append('No alerts\n', style='bold green')
            alert_text.append(
                'Parakeet is resident and Omi is ready. Start PTT or ambient recording to watch active load.',
                style='green',
            )
        alert_widget = self.query_one('#alerts', Static)
        alert_widget.set_class(overall == 'ok', 'ok')
        alert_widget.set_class(overall == 'warning', 'warning')
        alert_widget.set_class(overall == 'danger', 'danger')
        alert_widget.update(alert_text)

        process_table = self.query_one('#processes', DataTable)
        process_table.clear()
        for row in rows:
            process_table.add_row(*row)

        service_table = self.query_one('#services', DataTable)
        service_table.clear()
        service_table.add_row(
            'Parakeet LaunchAgent',
            value_text(parakeet_launchd, 'ok' if parakeet_launchd.startswith('running') else 'danger'),
        )
        service_table.add_row(
            'Proxy LaunchAgent', value_text(proxy_launchd, 'ok' if proxy_launchd.startswith('running') else 'danger')
        )
        service_table.add_row(
            'Parakeet port 8765', value_text(parakeet_port, 'ok' if parakeet_port == 'listening' else 'danger')
        )
        service_table.add_row(
            'Omi STT proxy port 8001', value_text(proxy_port, 'ok' if proxy_port == 'listening' else 'danger')
        )
        service_table.add_row('Log', '/Users/markus/Library/Logs/Omi/parakeet-stream.err')
        service_table.add_row('Proxy log', '/Users/markus/Library/Logs/Omi/parakeet-listen-proxy.err')


def main() -> None:
    parser = argparse.ArgumentParser(description='Live Textual monitor for Omi Local + Parakeet resources.')
    parser.add_argument('--interval', type=float, default=2.0, help='Refresh interval in seconds.')
    args = parser.parse_args()
    OmiParakeetMonitor(interval=args.interval).run()


if __name__ == '__main__':
    main()

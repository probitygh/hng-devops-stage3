#!/usr/bin/env python3
"""
FINAL Watcher - Exact Slack Format
"""

import os
import re
import time
import requests
from collections import deque
from datetime import datetime

class LogWatcher:
    def __init__(self):
        self.slack_webhook = os.getenv('SLACK_WEBHOOK_URL')
        self.log_file = '/var/log/nginx/access.log'
        self.error_threshold = 2.0
        self.window_size = 200
        self._total_lines_processed = 0
        
        # State tracking
        self.last_pool = None
        self.error_window = deque(maxlen=self.window_size)
        
        print("🚀 Watcher Started - EXACT SLACK FORMAT")
        print(f"📊 Slack: {'✅' if self.slack_webhook else '❌'}")

    def send_slack_alert(self, alert_data):
        """Send alert to Slack with the exact format you want"""
        if not self.slack_webhook:
            print(f"📝 Slack webhook not configured. Would send: {alert_data}")
            return False
            
        try:
            if alert_data['type'] == 'failover':
                message = {
                    "text": "🚨 Blue/Green Failover Detected",
                    "blocks": [
                        {
                            "type": "header",
                            "text": {
                                "type": "plain_text",
                                "text": "🚨 Blue/Green Failover Detected"
                            }
                        },
                        {
                            "type": "section",
                            "fields": [
                                {
                                    "type": "mrkdwn",
                                    "text": f"*From:* {alert_data['from_pool']}"
                                },
                                {
                                    "type": "mrkdwn", 
                                    "text": f"*To:* {alert_data['to_pool']}"
                                }
                            ]
                        },
                        {
                            "type": "section",
                            "fields": [
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Time:* {alert_data['timestamp']}"
                                },
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Requests Processed:* {self._total_lines_processed}"
                                }
                            ]
                        },
                        {
                            "type": "context",
                            "elements": [
                                {
                                    "type": "mrkdwn",
                                    "text": "Check the health of the primary container and investigate the cause."
                                }
                            ]
                        }
                    ]
                }
                
            else:  # high_error_rate
                message = {
                    "text": "⚠️ High Error Rate Detected",
                    "blocks": [
                        {
                            "type": "header",
                            "text": {
                                "type": "plain_text", 
                                "text": "⚠️ High Error Rate Detected"
                            }
                        },
                        {
                            "type": "section",
                            "fields": [
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Error Rate:* {alert_data['error_rate']}%"
                                },
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Threshold:* {alert_data['threshold']}%"
                                }
                            ]
                        },
                        {
                            "type": "section", 
                            "fields": [
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Errors:* {alert_data['error_count']}/{alert_data['window_size']}"
                                },
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Time:* {alert_data['timestamp']}"
                                }
                            ]
                        },
                        {
                            "type": "section",
                            "fields": [
                                {
                                    "type": "mrkdwn", 
                                    "text": f"*Total Requests:* {self._total_lines_processed}"
                                },
                                {
                                    "type": "mrkdwn",
                                    "text": f"*Window:* {alert_data['window_size']} requests"
                                }
                            ]
                        },
                        {
                            "type": "context",
                            "elements": [
                                {
                                    "type": "mrkdwn",
                                    "text": "Investigate upstream service logs and consider failover if necessary."
                                }
                            ]
                        }
                    ]
                }

            response = requests.post(
                self.slack_webhook,
                json=message,
                headers={'Content-Type': 'application/json'},
                timeout=10
            )
            
            if response.status_code == 200:
                print(f"✅ Alert sent successfully to Slack!")
                return True
            else:
                print(f"❌ Failed to send Slack alert. Status: {response.status_code}")
                return False
                
        except Exception as e:
            print(f"❌ Error sending Slack alert: {str(e)}")
            return False

    def check_failover(self, log_data):
        """Check if a failover has occurred"""
        if not log_data['pool'] or log_data['pool'] == 'unknown':
            return False
            
        if self.last_pool and self.last_pool != log_data['pool']:
            failover_event = {
                'from_pool': self.last_pool,
                'to_pool': log_data['pool'],
                'timestamp': log_data['timestamp'],
                'type': 'failover'
            }
            
            print("🎯" * 20)
            print(f"🚨 FAILOVER DETECTED: {self.last_pool} → {log_data['pool']}")
            print("🎯" * 20)
            
            self.last_pool = log_data['pool']
            return failover_event
        
        self.last_pool = log_data['pool']
        return False

    def check_error_rate(self, log_data):
        """Check if error rate exceeds threshold - COUNTS 4XX AND 5XX ERRORS"""
        if not log_data['upstream_status']:
            return False
            
        # Count both 4xx AND 5xx errors as errors
        status = log_data['upstream_status']
        is_error = status.startswith('4') or status.startswith('5')
        self.error_window.append(is_error)
        
        current_window_size = len(self.error_window)
        
        if current_window_size < self.window_size:
            return False
            
        error_count = sum(self.error_window)
        error_rate = (error_count / current_window_size) * 100
        
        if error_rate > self.error_threshold:
            error_alert = {
                'error_rate': round(error_rate, 2),
                'threshold': self.error_threshold,
                'window_size': current_window_size,
                'error_count': error_count,
                'timestamp': log_data['timestamp'],
                'type': 'high_error_rate'
            }
            
            print("⚠️" * 20)
            print(f"📈 HIGH ERROR RATE: {error_rate:.1f}% (threshold: {self.error_threshold}%)")
            print(f"   Errors: {error_count}/{current_window_size}")
            print("⚠️" * 20)
            
            return error_alert
        
        return False

    def watch_logs(self):
        """Main monitoring loop"""
        print(f"🔍 Watching: {self.log_file}")
        
        if not os.path.exists(self.log_file):
            print("❌ Log file not found")
            return

        try:
            # Process existing logs first
            with open(self.log_file, 'r') as file:
                existing_lines = file.readlines()
                for line in existing_lines:
                    self._total_lines_processed += 1
                    self.process_log_line(line)
                
                print(f"✅ Processed {len(existing_lines)} existing lines")
            
            # Monitor for new logs
            with open(self.log_file, 'r') as file:
                file.seek(0, 2)
                
                while True:
                    current_pos = file.tell()
                    line = file.readline()
                    
                    if not line:
                        file.seek(current_pos)
                        time.sleep(1)
                        continue
                    
                    self._total_lines_processed += 1
                    self.process_log_line(line)
                        
        except Exception as e:
            print(f"💥 Error: {e}")
            raise

    def process_log_line(self, line):
        """Process a single log line"""
        pool_match = re.search(r'pool="([^"]*)"', line)
        status_match = re.search(r'upstream_status=([\d-]+)', line)
        
        if pool_match and status_match:
            current_pool = pool_match.group(1)
            status = status_match.group(1)
            
            log_data = {
                'pool': current_pool,
                'upstream_status': status,
                'timestamp': datetime.now().isoformat()
            }
            
            # Check failover
            failover_alert = self.check_failover(log_data)
            if failover_alert:
                self.send_slack_alert(failover_alert)
            
            # Check error rate
            error_alert = self.check_error_rate(log_data)
            if error_alert:
                self.send_slack_alert(error_alert)

def main():
    watcher = LogWatcher()
    watcher.watch_logs()

if __name__ == '__main__':
    main()
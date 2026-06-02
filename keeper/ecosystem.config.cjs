// pm2 process config for the twentyeight-lend keeper + monitor.
// Both load ./.env via Node's --env-file. Run from the keeper/ directory:
//   pm2 start ecosystem.config.cjs
//   pm2 logs tw28-keeper   (or tw28-monitor)
//   pm2 save                (persist across reboots)
module.exports = {
  apps: [
    {
      name: "tw28-keeper",
      script: "keeper.mjs",
      node_args: "--env-file=.env",
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,
      time: true,
    },
    {
      name: "tw28-monitor",
      script: "monitor.mjs",
      node_args: "--env-file=.env",
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,
      time: true,
    },
  ],
};

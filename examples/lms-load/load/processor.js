// Artillery processor: stop every virtual user at a fixed wall-clock deadline,
// so a degraded service (e.g. an exhausted connection pool) does not stretch
// the run. run.sh replaces __DURATION_MS__.
'use strict';
const DEADLINE = Date.now() + __DURATION_MS__;

function beforeDeadline(context, next) {
  return next(Date.now() < DEADLINE);
}

module.exports = { beforeDeadline };

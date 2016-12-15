/* eslint-disable func-names, space-before-function-paren, wrap-iife, no-var, quotes, quote-props, prefer-template, comma-dangle, padded-blocks, max-len */
/* global BranchGraph */

(function() {
  this.Network = (function() {
    function Network(opts) {
      var vph;
      $("#filter_ref").click(function() {
        return $(this).closest('form').submit();
      });
      this.branch_graph = new BranchGraph($(".network-graph"), opts);
      vph = $(window).height() - 250;
      $('.network-graph').css({
        'height': vph + 'px'
      });
    }

    return Network;

  })();

}).call(this);

/* eslint-disable no-param-reassign */
/*= require filtered_search/filtered_search_dropdown */

((global) => {
  class DropdownAuthor extends gl.FilteredSearchDropdown {
    constructor(droplab, dropdown, input) {
      super(droplab, dropdown, input);
      this.listId = 'js-dropdown-author';
    }

    itemClicked(e) {
      const username = e.detail.selected.querySelector('.dropdown-light-content').innerText.trim();
      gl.FilteredSearchManager.addWordToInput(this.getSelectedText(username));

      this.dismissDropdown();
    }

    renderContent() {
      // TODO: Pass elements instead of querySelectors
      this.droplab.changeHookList(this.hookId, '#js-dropdown-author', [droplabAjaxFilter], {
        droplabAjaxFilter: {
          endpoint: '/autocomplete/users.json',
          searchKey: 'search',
          params: {
            per_page: 20,
            active: true,
            project_id: 2,
            current_user: true,
          },
          searchValueFunction: this.getSearchInput,
        }
      });
    }

    getSearchInput() {
      const query = document.querySelector('.filtered-search').value;
      const { value } = gl.FilteredSearchTokenizer.getLastTokenObject(query);
      const valueWithoutColon = value.slice(1);
      const hasPrefix = valueWithoutColon[0] === '@';
      const valueWithoutPrefix = valueWithoutColon.slice(1);

      if (hasPrefix) {
        return valueWithoutPrefix;
      } else {
        return valueWithoutColon;
      }
    }
  }

  global.DropdownAuthor = DropdownAuthor;
})(window.gl || (window.gl = {}));

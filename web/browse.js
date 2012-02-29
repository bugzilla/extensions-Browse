function setCaretToEnd (control) {
  if (control.createTextRange) {
    var range = control.createTextRange();
    range.collapse(false);
    range.select();
  }
  else if (control.setSelectionRange) {
    control.focus();
    var length = control.value.length;
    control.setSelectionRange(length, length);
  }
}

function addText(text) {
  /* Get the querytype */
  var colonloc = text.indexOf(":");
  var querytype;
  var searchBox = document.getElementById('boogle_search_box');

  if (colonloc != -1)
    querytype = text.substring(0,colonloc);
  else { 
    /* comment or +critical_warning */
    var oldvalue = searchBox.value;
    var location = oldvalue.indexOf(text);

    if (location == -1) {
      /* This is new; just prepend it */
      searchBox.value = text + " " + oldvalue;

    } else {
      searchBox.value = oldvalue.substring(0, location)
                        + oldvalue.substring(location + text.length + 1);
    }
    return;
  } /* if (colonloc != -1) */

  /* Quote the value, if needed */
  var value = text.substring(colonloc+1);
  if (value.match(/^[A-Za-z0-9+][A-Za-z0-9_\.-]*$/)) {
  } else {
    if (colonloc != -1)
      text = querytype + ':' + '"' + value + '"';
    else
      text = '"' + value + '"';

    value = '"' + value + '"';
  }

  /* Find if this querytype is already in the boogle query */
  var oldvalue = searchBox.value;
  var location = oldvalue.search(querytype);

  if (location == -1) {
    /* This is a new query type; just prepend it */
    searchBox.value = text + " " + oldvalue;
  } else {
    /* This querytype already appears, so doing an and with a different
     * value does not make any sense.  So, just add it as a comma separated
     * list item if it is not already present; otherwise, remove it.
     */

    if (oldvalue.search(value) == -1) {
      /* prepend the new value */
      searchBox.value = oldvalue.substring(0,location) + text + "," 
                        + oldvalue.substring(location + querytype.length + 1);

    } else {

      /* value is already in list, remove it */
      var vlocation = oldvalue.indexOf(value);
    
      /* how many values are there for the current querytype? */
      var queryvalues = oldvalue.substring(location + querytype.length + 1);
      if (queryvalues.indexOf(":") >= 0) {
        /* other querytypes follow, discard them */
        queryvalues = queryvalues.substring(0,queryvalues.indexOf(":") - 1);
      }

      /* count the commas (up to the next colon) */
      var numberofvalues = 1;
      while ( queryvalues.indexOf(",") >= 0 ) {
        queryvalues = queryvalues.substring(queryvalues.indexOf(",")+1);
        numberofvalues += 1;
      }

      if (numberofvalues == 1) {
        /* remove the querytype name and value */
        searchBox.value = oldvalue.substring(0,location)
                          + oldvalue.substring(vlocation + value.length + 1);
      } else {
        /* only remove one value */

        /* last of all value in querytype? 
           then do not remove the trailing but the preceding character */

        if ( (vlocation + value.length == oldvalue.length) /*last in string? */
            ||
             (oldvalue.substring(vlocation + value.length, /*trailing space? */
              vlocation + value.length + 1) == ' ')   
           ) 
        {
          searchBox.value = oldvalue.substring(0,vlocation-1)
                            + oldvalue.substring(vlocation + value.length);

        } else {
          searchBox.value = oldvalue.substring(0,vlocation)
                            + oldvalue.substring(vlocation + value.length + 1);
        }
      } /* if(numberofvalues == 1) */

    } /* if(oldvalue.search(value) == -1) */

  } /* if (location == -1) */
}


# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Browse Bugzilla Extension.
#
# The Initial Developer of the Original Code is YOUR NAME
# Portions created by the Initial Developer are Copyright (C) 2011 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   YOUR NAME <YOUR EMAIL ADDRESS>

package Bugzilla::Extension::Browse::Util;
use strict;
use base qw(Exporter);
our @EXPORT = qw(
    page
    total_open_bugs
    what_new_means
    new_bugs
    new_patches
    keyword_bugs
    no_response_bugs
    critical_warning_bugs
    string_bugs
    by_patch_status
    by_version
    needinfo_split
    by_target
    by_priority
    by_severity
    by_component
    by_assignee
    gnome_target_development 
    gnome_target_stable
    list_blockers
    browse_bug_link
);

# This file can be loaded by your extension via 
# "use Bugzilla::Extension::Browse::Util". You can put functions
# used by your extension in here. (Make sure you also list them in
# @EXPORT.)

use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Search;
use Bugzilla::Field;
use Bugzilla::Status;
use Bugzilla::Util;
use Bugzilla::Install::Util qw(vers_cmp);

use constant IMPORTANT_PATCH_STATUSES => qw(
    none
    accepted-commit_now
    accepted-commit_after_freeze
);

sub page {
    my %params = @_;
    my ($vars, $page) = @params{qw(vars page_id)};
    if ($page =~ /^browse\./) {
        _page_browse($vars);
    }
}

sub _page_browse {
    my $vars = shift;

    my $cgi = Bugzilla->cgi;
    my $dbh = Bugzilla->dbh;
    my $user = Bugzilla->user;
    my $template = Bugzilla->template;

    # All pages point to the same part of the documentation.
    $vars->{'doc_section'} = 'bugreports.html';

    my $product_name = trim($cgi->param('product') || '');
    my $product;

    if (!$product_name && $cgi->cookie('DEFAULTPRODUCT')) {
        $product_name = $cgi->cookie('DEFAULTPRODUCT')
            if $user->can_enter_product($cgi->cookie('DEFAULTPRODUCT'));
    }

    my $product_interests = $user->product_interests();

    # If the user didn't select a product and there isn't a default from a cookie,
    # try getting the first valid product from their interest list.
    if (!$product_name && scalar @$product_interests) {
        foreach my $try (@$product_interests) {
            next if !$user->can_see_product($try->name);
            $product_name = $try->name;
            last;
        }
    }

    if ($product_name eq '') {
        # If the user cannot enter bugs in any product, stop here.
        my @enterable_products = @{$user->get_enterable_products};
        ThrowUserError('no_products') unless scalar(@enterable_products);

        my $classification = Bugzilla->params->{'useclassification'} ?
            scalar($cgi->param('classification')) : '__all';

        # Unless a real classification name is given, we sort products
        # by classification.
        my @classifications;

        unless ($classification && $classification ne '__all') {
            if (Bugzilla->params->{'useclassification'}) {
                my $class;
                # Get all classifications with at least one enterable product.
                foreach my $product (@enterable_products) {
                    $class->{$product->classification_id}->{'object'} ||=
                        new Bugzilla::Classification($product->classification_id);
                    # Nice way to group products per classification, without querying
                    # the DB again.
                    push(@{$class->{$product->classification_id}->{'products'}}, $product);
                }
                @classifications = sort {$a->{'object'}->sortkey <=> $b->{'object'}->sortkey
                                         || lc($a->{'object'}->name) cmp lc($b->{'object'}->name)}
                                        (values %$class);
            }
            else {
                @classifications = ({object => undef, products => \@enterable_products});
            }
        }

        unless ($classification) {
            # We know there is at least one classification available,
            # else we would have stopped earlier.
            if (scalar(@classifications) > 1) {
                # We only need classification objects.
                $vars->{'classifications'} = [map {$_->{'object'}} @classifications];

                $vars->{'target'} = "browse.cgi";
                $vars->{'format'} = $cgi->param('format');

                print $cgi->header();
                $template->process("global/choose-classification.html.tmpl", $vars)
                   || ThrowTemplateError($template->error());
                exit;
            }
            # If we come here, then there is only one classification available.
            $classification = $classifications[0]->{'object'}->name;
        }

        # Keep only enterable products which are in the specified classification.
        if ($classification ne "__all") {
            my $class = new Bugzilla::Classification({'name' => $classification});
            # If the classification doesn't exist, then there is no product in it.
            if ($class) {
                @enterable_products
                  = grep {$_->classification_id == $class->id} @enterable_products;
                @classifications = ({object => $class, products => \@enterable_products});
            }
            else {
                @enterable_products = ();
            }
        }

        if (scalar(@enterable_products) == 0) {
            ThrowUserError('no_products');
        }
        elsif (scalar(@enterable_products) > 1) {
            $vars->{'classifications'} = \@classifications;
            $vars->{'target'} = "browse.cgi";
            $vars->{'format'} = $cgi->param('format');

            print $cgi->header();
            $template->process("global/choose-product.html.tmpl", $vars)
              || ThrowTemplateError($template->error());
            exit;
        } else {
            # Only one product exists.
            $product = $enterable_products[0];
        }
    }
    else {
        # Do not use Bugzilla::Product::check_product() here, else the user
        # could know whether the product doesn't exist or is not accessible.
        $product = new Bugzilla::Product({'name' => $product_name});
    }

    # We need to check and make sure that the user has permission
    # to enter a bug against this product.
    $user->can_enter_product($product ? $product->name : $product_name, THROW_ERROR);

    # Remember selected product
    $cgi->send_cookie(-name => 'DEFAULTPRODUCT',
                      -value => $product->name,
                      -expires => "Fri, 01-Jan-2038 00:00:00 GMT");

    # Create data structures representing each classification
    my @classifications = (); 
    if (scalar @$product_interests) {
        my %watches = ( 
            'name'     => 'Watched Products',
            'products' => $product_interests
        );  
        push @classifications, \%watches;
    }

    if (Bugzilla->params->{'useclassification'}) {
        foreach my $c (@{$user->get_selectable_classifications}) {
            # Create hash to hold attributes for each classification.
            my %classification = ( 
                'name'       => $c->name, 
                'products'   => [ @{$user->get_selectable_products($c->id)} ]
            );  
            # Assign hash back to classification array.
            push @classifications, \%classification;
        }   
    }

    $vars->{'classifications'}  = \@classifications;
    $vars->{'product'}          = $product;
    $vars->{'total_open_bugs'}  = total_open_bugs($product);
    $vars->{'what_new_means'}   = what_new_means();
    $vars->{'new_bugs'}         = new_bugs($product);
    $vars->{'new_patches'}      = new_patches($product);
    $vars->{'no_response_bugs'} = scalar(@{no_response_bugs($product)});

    my $keyword = Bugzilla::Keyword->new({ name => 'gnome-love' });
    if ($keyword) {
        $vars->{'gnome_love_bugs'}  = keyword_bugs($product, $keyword);
    }

    ######################################################################
    # Begin temporary searches; If the search will be reused again next
    # release cycle, please just comment it out instead of deleting it.
    ######################################################################

    $vars->{'critical_warning_bugs'} = critical_warning_bugs($product);
    #$vars->{'string_bugs'} = string_bugs($product);

    ######################################################################
    # End temporary searches
    ######################################################################

    $vars->{'by_patch_status'}    = by_patch_status($product);
    $vars->{'buglink'}            = browse_bug_link($product);
    $vars->{'by_version'}         = by_version($product);
    $vars->{'by_target'}          = by_target($product);
    $vars->{'by_priority'}        = by_priority($product);
    $vars->{'by_severity'}        = by_severity($product);
    $vars->{'by_component'}       = by_component($product);
    $vars->{'target_development'} = gnome_target_development();
    $vars->{'target_stable'}      = gnome_target_stable();
    $vars->{'needinfo_split'}     = needinfo_split($product);

    ($vars->{'blockers_stable'}, $vars->{'blockers_development'}) = list_blockers($product);

    print Bugzilla->cgi->header();

#    my $format = $template->get_format("browse/main",
#                                       scalar $cgi->param('format'),
#                                       scalar $cgi->param('ctype'));
#     
#    print $cgi->header($format->{'ctype'});
#    $template->process($format->{'template'}, $vars)
#       || ThrowTemplateError($template->error());
}

sub browse_open_states {
    my $dbh = Bugzilla->dbh;
    return join(",", map { $dbh->quote($_) } grep($_ ne "NEEDINFO", BUG_STATE_OPEN));
}

sub total_open_bugs {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    return $dbh->selectrow_array("SELECT COUNT(bug_id) 
                                    FROM bugs 
                                   WHERE bug_status IN (" . browse_open_states() . ") 
                                         AND product_id = ?", undef, $product->id);
}

sub what_new_means {
    my $dbh = Bugzilla->dbh;
    return $dbh->selectrow_array("SELECT " . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', 7, 'DAY'));
}

sub new_bugs {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    return $dbh->selectrow_array("SELECT COUNT(bug_id) 
                                    FROM bugs 
                                   WHERE bug_status IN (" . browse_open_states() . ") 
                                         AND creation_ts >= " . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', 7, 'DAY') . " 
                                         AND product_id = ?", undef, $product->id);
}

sub new_patches {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    return $dbh->bz_column_info('attachments', 'status') ?
           $dbh->selectrow_array("SELECT COUNT(attach_id) 
                                    FROM bugs, attachments 
                                   WHERE bugs.bug_id = attachments.bug_id
                                         AND bug_status IN (" . browse_open_states() . ") 
                                         AND attachments.ispatch = 1 AND attachments.isobsolete = 0
                                         AND attachments.status = 'none' 
                                         AND attachments.creation_ts >= " . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', 7, 'DAY') . " 
                                         AND product_id = ?", undef, $product->id) :
          "?";
}

sub keyword_bugs {
    my ($product, $keyword) = @_;
    my $dbh = Bugzilla->dbh;

    return $dbh->selectrow_array("SELECT COUNT(bugs.bug_id) 
                                    FROM bugs, keywords 
                                   WHERE bugs.bug_id = keywords.bug_id 
                                         AND bug_status IN (" . browse_open_states() . ") 
                                         AND keywords.keywordid = ? 
                                         AND product_id = ?", undef, ($keyword->id, $product->id));
}

sub no_response_bugs {
    my $product = shift;
    my $dbh = Bugzilla->dbh;
    my @developer_ids = map { $_->id } @{$product->developers};

    if (@developer_ids) {
        return $dbh->selectcol_arrayref("SELECT bugs.bug_id
                                           FROM bugs INNER JOIN longdescs ON longdescs.bug_id = bugs.bug_id 
                                          WHERE bug_status IN (" . browse_open_states() . ") 
                                                AND bug_severity != 'enhancement' 
                                                AND product_id = ? 
                                                AND bugs.reporter NOT IN (" . join(",", @developer_ids) . ") 
                                          GROUP BY bugs.bug_id 
                                         HAVING COUNT(distinct longdescs.who) = 1", undef, $product->id);
    }
    else {
        return [];
    }
}

sub critical_warning_bugs {
    my $product = shift;
    my $dbh = Bugzilla->dbh;
 
    return $dbh->selectrow_array("SELECT COUNT(bugs.bug_id) 
                                    FROM bugs INNER JOIN bugs_fulltext ON bugs_fulltext.bug_id = bugs.bug_id 
                                   WHERE bug_status IN (" . browse_open_states() . ") 
                                         AND " . $dbh->sql_fulltext_search("bugs_fulltext.comments_noprivate", "'+G_LOG_LEVEL_CRITICAL'") . " 
                                         AND product_id = ?", undef, $product->id);
}

sub string_bugs {
    my $product = shift;
    my $dbh = Bugzilla->dbh;
    
    return $dbh->selectrow_array("SELECT COUNT(bugs.bug_id) 
                                    FROM bugs, keywords, keyworddefs 
                                   WHERE bugs.bug_id = keywords.bug_id 
                                         AND keywords.keywordid = keyworddefs.id 
                                         AND keyworddefs.name = 'string' 
                                         AND bug_status IN (" . browse_open_states() . ") 
                                         AND product_id = ?", undef, $product->id);
}

sub by_patch_status {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    return $dbh->bz_column_info('attachments', 'status') ?
           $dbh->selectall_arrayref("SELECT attachments.status, COUNT(attach_id) 
                                       FROM bugs, attachments
                                      WHERE attachments.bug_id = bugs.bug_id 
                                            AND bug_status IN (" . browse_open_states() . ") 
                                            AND product_id = ? 
                                            AND attachments.ispatch = 1 
                                            AND attachments.isobsolete != 1 
                                            AND attachments.status IN (" . join(",", map { $dbh->quote($_) } IMPORTANT_PATCH_STATUSES) . ") 
                                            GROUP BY attachments.status", undef, $product->id) :
           "?";
}

sub browse_bug_link {
    my $product = shift;

    return correct_urlbase() . 'buglist.cgi?product=' . url_quote($product->name) .
           '&bug_status=' . join(',' ,map { url_quote($_) } grep ($_ ne "NEEDINFO", BUG_STATE_OPEN));
}

sub by_version {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my @result = sort { vers_cmp($a->[0], $b->[0]) } 
        @{$dbh->selectall_arrayref("SELECT version, COUNT(bug_id) 
                                      FROM bugs 
                                     WHERE bug_status IN (" . browse_open_states() . ") 
                                           AND product_id = ? 
                                     GROUP BY version", undef, $product->id)};
    
    return \@result;
}

sub needinfo_split {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my $ni_a = Bugzilla::Search::SqlifyDate('-2w');
    my $ni_b = Bugzilla::Search::SqlifyDate('-4w');
    my $ni_c = Bugzilla::Search::SqlifyDate('-3m');
    my $ni_d = Bugzilla::Search::SqlifyDate('-6m');
    my $ni_e = Bugzilla::Search::SqlifyDate('-1y');
    my $needinfo_case = "CASE WHEN delta_ts < '$ni_e' THEN 'F'
                              WHEN delta_ts < '$ni_d' THEN 'E'
                              WHEN delta_ts < '$ni_c' THEN 'D'
                              WHEN delta_ts < '$ni_b' THEN 'C'
                              WHEN delta_ts < '$ni_a' THEN 'B'
                              ELSE 'A' END";

    my %results = @{$dbh->selectcol_arrayref("SELECT $needinfo_case age, COUNT(bug_id) 
                                       FROM bugs 
                                      WHERE bug_status = 'NEEDINFO' 
                                            AND product_id = ? 
                                      GROUP BY $needinfo_case", { Columns=>[1,2] }, $product->id)};
    return \%results;
}

sub by_target {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my @result = sort { vers_cmp($a->[0], $b->[0]) } 
        @{$dbh->selectall_arrayref("SELECT target_milestone, COUNT(bug_id) 
                                      FROM bugs 
                                     WHERE bug_status IN (" . browse_open_states() . ") 
                                           AND target_milestone != '---' 
                                           AND product_id = ? 
                                     GROUP BY target_milestone", undef, $product->id)};
    
    return \@result;
}

sub by_priority {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my $i = 0;
    my %order_priority = map { $_ => $i++  } @{get_legal_field_values('priority')};
    
    my @result = sort { $order_priority{$a->[0]} <=> $order_priority{$b->[0]} } 
        @{$dbh->selectall_arrayref("SELECT priority, COUNT(bug_id) 
                                      FROM bugs 
                                     WHERE bug_status IN (" . browse_open_states() . ") 
                                           AND product_id = ? 
                                     GROUP BY priority", undef, $product->id)};

    return \@result;
}

sub by_severity {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my $i = 0;
    my %order_severity = map { $_ => $i++  } @{get_legal_field_values('bug_severity')};

    my @result = sort { $order_severity{$a->[0]} <=> $order_severity{$b->[0]} } 
        @{$dbh->selectall_arrayref("SELECT bug_severity, COUNT(bug_id) 
                                      FROM bugs 
                                     WHERE bug_status IN (" . browse_open_states() . ") 
                                           AND product_id = ? 
                                     GROUP BY bug_severity", undef, $product->id)};

    return \@result;
}

sub by_component {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    return $dbh->selectall_arrayref("SELECT components.name, COUNT(bugs.bug_id) 
                                       FROM bugs INNER JOIN components ON bugs.component_id = components.id 
                                      WHERE bug_status IN (" . browse_open_states() . ") 
                                            AND bugs.product_id = ? 
                                      GROUP BY components.name", undef, $product->id);
}

sub by_assignee {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my @result = map { Bugzilla::User->new($_) } 
        @{$dbh->selectall_arrayref("SELECT bugs.assignee AS userid, COUNT(bugs.bug_id) 
                                      FROM bugs 
                                     WHERE bug_status IN (" . browse_open_states() . ") 
                                           AND bugs.product_id = ? 
                                     GROUP BY components.name", undef, $product->id)};
    
    return \@result;
}

sub gnome_target_development { 
    my @legal_gnome_target = @{get_legal_field_values('cf_gnome_target')};
    return $legal_gnome_target[(scalar @legal_gnome_target) -1];
}

sub gnome_target_stable {
    my @legal_gnome_target = @{get_legal_field_values('cf_gnome_target')};
    return $legal_gnome_target[(scalar @legal_gnome_target) -2];
}

sub list_blockers {
    my $product = shift;
    my $dbh = Bugzilla->dbh;

    my $sth = $dbh->prepare("SELECT bugs.bug_id, products.name AS product, bugs.bug_status, 
                                        bugs.resolution, bugs.bug_severity, bugs.short_desc 
                                   FROM bugs INNER JOIN products ON bugs.product_id = products.id
                                  WHERE product_id = ? 
                                        AND bugs.cf_gnome_target = ? 
                                        AND bug_status IN (" . browse_open_states() . ") 
                                  ORDER BY bug_id DESC");

    my @list_blockers_development;
    $sth->execute($product->id, gnome_target_development());
    while (my $bug = $sth->fetchrow_hashref) {
        push(@list_blockers_development, $bug);
    }
    
    my @list_blockers_stable;
    $sth->execute($product->id, gnome_target_stable());
    while (my $bug = $sth->fetchrow_hashref) {
        push(@list_blockers_stable, $bug);
    }
    
    return (\@list_blockers_stable, \@list_blockers_development);
}

1;
